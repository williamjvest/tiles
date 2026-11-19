import Foundation
import Testing
@testable import ArriWebRemote
@testable import CameraCore

// MARK: - The protocol's pieces

private func fixtureSnapshot() throws -> ArriSnapshot {
    try ArriSnapshot(json: ["id": 1, "variables": ArriFixture.variables(), "commands": ArriFixture.commands])
}

private func fixtureReading() throws -> ArriReading {
    ArriReading(snapshot: try fixtureSnapshot(), catalog: ArriEnumCatalog(javascript: ArriFixture.script))
}

@Test func pageScriptGivesEnumOrderAndLabels() {
    let catalog = ArriEnumCatalog(javascript: ArriFixture.script)
    #expect(catalog.tokens(forVariable: "ExposureIndex")?.count == 14)
    #expect(catalog.label(variable: "ExposureIndex", index: 7) == "800")
    #expect(catalog.label(variable: "NDFilterPositionEffective", index: 3) == "ND 2.1", "the label, not the token")
    #expect(catalog.tokens(forVariable: "SystemCameraIndex")?.last == "Z", "a split list")
    #expect(catalog.label(variable: "PlaybackSpeedEnum", index: 12) == "2x")
    #expect(catalog.label(variable: "PlaybackSpeedEnum", index: 10) == "Pause", "no label: the token made readable")
    #expect(catalog.label(variable: "Nonsense", index: 0) == nil)
}

@Test func pageScriptReadsOtherSpellings() {
    // Single quotes, an array with a trailing comma, labels in an object literal.
    let script = """
        x.NDFilterPosition={type:'NDFilter',name:'NDFilterPosition'};
        q={NDFilter:['CLEAR','ZERO_POINT_SIX','ONE_POINT_TWO','TWO_POINT_ONE',]};
        i18n={en:{ENUM_NDFilter_CLEAR:"ND  -",ENUM_NDFilter_TWO_POINT_ONE:"ND 1.8"}};
        """
    let catalog = ArriEnumCatalog(javascript: script)
    #expect(catalog.tokens(forVariable: "NDFilterPosition")?.count == 4)
    #expect(catalog.label(variable: "NDFilterPosition", index: 3) == "ND 1.8")
    #expect(catalog.label(variable: "NDFilterPosition", index: 1) == "Zero Point Six")
    #expect(ArriFormat.ndLabel("Zero Point Six") == "0.6")
}

@Test func updatesMergeInEveryShape() throws {
    var snapshot = try fixtureSnapshot()
    #expect(snapshot.merge(update: ["id": 5, "variables": ["WBCurrentKelvin": ["value": 3200]]]) == ["WBCurrentKelvin"])
    #expect(snapshot.id == 5)
    #expect(snapshot.variables["WBCurrentKelvin"]?.value == .number(3200))
    #expect(snapshot.variables["WBCurrentKelvin"]?.max == 11000, "what the update doesn't carry stays")
    snapshot.merge(update: ["id": 6, "variables": ["WBCurrentKelvin": 4300]])
    #expect(snapshot.variables["WBCurrentKelvin"]?.value == .number(4300))
    #expect(snapshot.merge(update: ["id": 7, "WBCurrentKelvin": 5000, "ExposurePreferenceIsAngle": false])
            == ["ExposurePreferenceIsAngle", "WBCurrentKelvin"])
    #expect(snapshot.variables["ExposurePreferenceIsAngle"]?.value == .bool(false))
    #expect(snapshot.merge(update: ["id": 8, "variables": [:]]).isEmpty)
    #expect(snapshot.merge(update: ["id": 9, "changes": ["WBCurrentKelvin"], "result": 0]).isEmpty,
            "beside the id, only the camera's own names count")
    #expect(snapshot.variables["changes"] == nil)
    #expect(ArriValue.number(.nan).json is NSNull, "never a number JSON can't encode")
    #expect(Double(1e20).asInt == nil && Double.nan.asInt == nil && Double(-3.7).asInt == -3)
    #expect(snapshot.commandIDs(named: "PlayBackSkipClip") == [ArriFixture.skipBack, ArriFixture.skipForward])
}

@Test func valuesReadTheWayTilesShowThem() {
    #expect(ArriFormat.timecode(.string("14:22:01:12"))! == (14, 22, 1, 12))
    #expect(ArriFormat.timecode(.number(Double(0x1422_0112)))! == (14, 22, 1, 12), "BCD timecode")
    #expect(ArriFormat.timecode(.number(Double(0x1A00_0000))) == nil)
    #expect(ArriFormat.tStop(3000) == 2.8, "thousandths of a stop")
    #expect(ArriFormat.tStop(4.0) == 4.0)
    #expect(ArriFormat.ndLabel("ND  -") == "Clear")
    #expect(ArriFormat.ndLabel("ND 1.8") == "1.8")
    #expect(ArriFormat.ndLabel("TWO_POINT_ONE") == "2.1")
    #expect(ArriFormat.eiNumber("EI 1280") == 1280)
    #expect(ArriFormat.minutes(38) == 38)
    #expect(ArriFormat.minutes(2280) == 38, "seconds")
    #expect(ArriFormat.letter(.number(2), label: nil) == "C")
    #expect(ArriFormat.letter(.number(0), label: "A") == "A")
    #expect(ArriTables.speedLabel(angle: 172.8, fps: 24) == "1/50")
    #expect(ArriTables.angle(forSpeed: "1/48", fps: 24) == 180)
}

@Test func namesResolveExactlyThenByWords() {
    let names: Set<String> = ["CamRecState", "TimeCodeNow", "ClipNameCameraIndex", "ClipNameCurrent", "SystemCameraIndex",
                              "ExposureIndex", "RecordingResolution", "_LookFileName", "BatteryRemainingTime"]
    let fields = ArriNames.resolve(names)
    #expect(fields[.recState] == "CamRecState")
    #expect(fields[.timecode] == "TimeCodeNow")
    #expect(fields[.clipName] == "ClipNameCurrent")
    #expect(fields[.cameraIndex] == "SystemCameraIndex")
    #expect(fields[.sensorMode] == "RecordingResolution")
    #expect(fields[.look] == nil, "a UI-only variable is never matched by words")
    #expect(fields[.mediaRemaining] == nil, "battery time isn't media")
    #expect(ArriNames.words("SDI1FramelineOn") == ["sdi", "1", "frameline", "on"])
    #expect(ArriNames.words("WBCurrentKelvin") == ["wb", "current", "kelvin"])
}

@Test func outputsAndTheirSwitchesComeFromTheNames() throws {
    let reading = try fixtureReading()
    #expect(reading.outputs.map(\.id) == ["Sdi1", "Sdi2", "Evf"])
    #expect(reading.outputs.map(\.name) == ["SDI 1", "SDI 2", "EVF"])
    let evf = try #require(reading.outputs.first { $0.id == "Evf" })
    #expect(evf.switches[.lut]?.variable == "LookSwitchEvf")
    #expect(evf.switches[.frameGuides]?.variable == "FramelinesEvf")
    #expect(evf.switches[.falseColor] == ArriSwitch(variable: "ExposureToolEvf", on: .number(1), off: .number(0)))
    #expect(evf.switches[.zebra] == ArriSwitch(variable: "ExposureToolEvf", on: .number(2), off: .number(0)))
    #expect(evf.switches[.focusAssist] == ArriSwitch(variable: "FocusToolEvf", on: .number(1), off: .number(0)))
    #expect(evf.switches[.statusText]?.variable == "OverlaysEvf")
    #expect(!evf.switches.values.contains { $0.variable == "ZebraLevelEvf" }, "a level isn't a switch")
}

@Test func fixtureReadsAsAnAlexaMini() throws {
    var state = CameraState()
    try fixtureReading().apply(to: &state, host: "203.0.113.120")
    #expect(state.make == .arri)
    #expect(state.model == "ALEXA Mini")
    #expect(state.recording.state == .idle)
    #expect(state.iso?.value == 800)
    #expect(state.iso?.options.count == 14)
    #expect(state.iso?.isWritable == true)
    #expect(state.nativeISOs == [800])
    #expect(state.nd?.preset.value == "0.6")
    #expect(state.nd?.preset.options == ["Clear", "0.6", "1.2", "2.1"])
    #expect(state.whiteBalance?.kelvin.value == 5600)
    #expect(state.whiteBalance?.kelvin.range == 2000...11000)
    #expect(state.whiteBalance?.tint?.range == -16...16)
    #expect(state.whiteBalance?.preset.value == "5600K")
    #expect(state.shutterAngle?.value == 172.8)
    #expect(state.shutterSpeed?.value == "1/50")
    #expect(state.shutterMode?.value == .angle)
    #expect(state.frameRate?.project.value == "24")
    #expect(state.frameRate?.project.options.contains("200") == true)
    #expect(state.resolution?.value == "3.4K Open Gate")
    #expect(state.fileFormat?.options == ["ARRIRAW", "ProRes 4444"], "what the camera can't pick now isn't offered")
    #expect(state.lut?.options == ["ARRI 709", "Toldwell Show Look"])
    #expect(state.colorBars?.value == false)
    #expect(state.iris?.value == 2.8)
    #expect(state.iris?.isWritable == false)
    #expect(state.mediaRemainingMinutes == 38)
    #expect(state.fileNaming?.cameraID?.value == "A")
    #expect(state.fileNaming?.reel?.value == 4)
    #expect(state.clipName == "A004C012_261022_R1AB")
    #expect(state.timecode?.rate == 24)
    #expect(state.monitoring?.outputs.count == 3)
    #expect(state.look?.value == false, "SDI 2 has its look off")
    #expect(state.monitoring?.outputs.first { $0.id == "Sdi2" }?.overlays[.zebra]?.value == true)
    #expect(state.playback?.isPlaying == false)
    #expect(state.playback?.inReview == false)
    #expect(state.playback?.clipCount == 11)
    #expect(state.webRemoteURL?.absoluteString == "http://203.0.113.120/")
}

@Test func withoutThePageScriptTilesTablesLabelEIAndND() throws {
    let snapshot = try fixtureSnapshot()
    let mini = ArriEnumCatalog.fallback(for: snapshot, model: "ALEXA Mini")
    #expect(mini.label(variable: "ExposureIndex", index: 7) == "800")
    #expect(mini.label(variable: "NDFilterPosition", index: 3).map(ArriFormat.ndLabel) == "2.1")
    let lf = ArriEnumCatalog.fallback(for: snapshot, model: "ALEXA Mini LF")
    #expect(lf.label(variable: "NDFilterPosition", index: 3).map(ArriFormat.ndLabel) == "1.8")
    let thirtyFive = ArriEnumCatalog.fallback(for: snapshot, model: "ALEXA 35")
    #expect(thirtyFive.tokens(forVariable: "ExposureIndex") == nil, "a list of another length isn't guessed at")
}

// MARK: - The backend against a fake camera

private final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraState()
    var state: CameraState { lock.withLock { value } }
    func set(_ s: CameraState) { lock.withLock { value = s } }
}

private func connected(_ fake: FakeArriCamera, cache: URL? = nil,
                       configure: ((ArriCameraBackend) async -> Void)? = nil) async throws -> (ArriCameraBackend, Latest, Task<Void, Never>) {
    let backend = ArriCameraBackend(host: fake.host, cacheDirectory: cache)
    await backend.configure(recConfirmTimeout: 2)
    await configure?(backend)
    let latest = Latest()
    let listening = Task { for await s in backend.updates { latest.set(s) } }
    await backend.connect()
    #expect(await waitFor { latest.state.connection == .connected }, "connected")
    return (backend, latest, listening)
}

private func waitFor(seconds: Double = 4, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test func backendConnectsAndFollowsTheCamera() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(latest.state.model == "ALEXA Mini")
    #expect(latest.state.iso?.value == 800)
    fake.change("WBCurrentKelvin", 3200)
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 3200 }, "a change on the body arrives by the long poll")
    #expect(fake.paths.contains { $0.hasPrefix("/update.cgi?id=") })
    fake.change("NDFilterPosition", 3)
    #expect(await waitFor { latest.state.nd?.preset.value == "2.1" })
    await backend.disconnect()
}

@Test func backendWritesInTheCamerasTerms() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.setISO(1600))
    #expect(fake.sets.last?["ExposureIndex"] as? Int == 10, "EI goes as its index")
    await backend.send(.setNDPreset("1.2"))
    #expect(fake.sets.last?["NDFilterPosition"] as? Int == 2)
    await backend.send(.setWhiteBalancePreset("3200K"))
    #expect(fake.sets.last?["WBCurrentKelvin"] as? Int == 3200)
    #expect(fake.sets.last?["WBCurrentColorComp"] as? Int == 0, "a preset sets CC back to 0, in one call")
    await backend.send(.setShutterSpeed("1/48"))
    #expect(fake.sets.last?["ShutterNominal"] as? Int == 180, "a time is the angle at this frame rate")
    await backend.send(.setFrameRate("25"))
    #expect(fake.sets.last?["FPSNominal"] as? Int == 25)
    await backend.send(.setMonitorOverlay(.falseColor, true, output: "Sdi1"))
    #expect(fake.sets.last?["ExposureToolSdi1"] as? Int == 1)
    let before = fake.sets.count
    await backend.send(.setMonitorOverlay(.zebra, false, output: nil))
    #expect(fake.sets.count == before + 1)
    #expect(fake.sets.last?.keys.sorted() == ["ExposureToolSdi2"], "only where zebra was on")
    await backend.send(.setFileFormat("ProRes 422 HQ"))
    #expect(fake.sets.count == before + 1, "a codec the camera can't pick now isn't sent")
    await backend.send(.setClipCameraID("C"))
    #expect(fake.sets.last?["SystemCameraIndex"] as? Int == 2)
    #expect(await waitFor { latest.state.iso?.value == 1600 && latest.state.nd?.preset.value == "1.2" })
    await backend.disconnect()
}

@Test func recordIsConfirmedByTheCamera() async throws {
    let fake = FakeArriCamera(config: .init(recDelay: 0.3))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    let rolling = Task { await backend.send(.record(true)) }
    #expect(await waitFor { latest.state.recording.request == .start }, "asked, not assumed")
    #expect(latest.state.recording.state == .idle)
    await rolling.value
    #expect(await waitFor { latest.state.recording.state == .recording && latest.state.recording.request == nil })
    #expect(await waitFor { latest.state.frameRate?.project.isWritable == false },
            "rolling locks the frame rate, and Tiles reads the new flags")
    let before = fake.sets.count
    await backend.send(.setFrameRate("25"))
    #expect(fake.sets.count == before, "nothing sent to a locked setting")
    #expect(fake.calls.last?["command"] as? String == ArriFixture.recStart)
    let calls = fake.calls.count
    await backend.send(.record(true))
    #expect(fake.calls.count == calls, "already rolling: nothing sent")
    await backend.send(.record(false))
    #expect(fake.calls.last?["command"] as? String == ArriFixture.recStop)
    #expect(await waitFor { latest.state.recording.state == .idle })
    await backend.disconnect()
}

@Test func playbackCuesTheCardWithClips() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.play))
    let prepare = try #require(fake.calls.first)
    // The fixture has one PlayBackPrepare id; card A is selected (only card A has clips).
    #expect(prepare["command"] as? String == "_EeUkIwIBEeSgptigTra4vQ")
    let set = prepare["set"] as? [String: Any]
    // The Mini's page sends {"_TableVersion_Local": <version>}; PlaybackMediumSelected_Local is not sent.
    #expect(set?["_TableVersion_Local"] as? Int == 3, "clip table version for card A")
    #expect(set?["PlaybackMediumSelected_Local"] == nil, "Mini payload does not include PlaybackMediumSelected_Local")
    #expect(fake.calls.last?["command"] as? String == "_7q_F4cHREeStK8NH8ZPGbQ")
    #expect(await waitFor { latest.state.playback?.isPlaying == true && latest.state.playback?.inReview == true })
    await backend.send(.playback(.next))
    #expect(fake.calls.last?["command"] as? String == ArriFixture.skipForward)
    await backend.send(.playback(.fastForward))
    #expect(fake.sets.last?["PlaybackSpeedEnum"] as? Int == 12, "FWD_2")
    await backend.send(.playback(.live))
    #expect(fake.calls.last?["command"] as? String == "_cCCFscHSEeStK8NH8ZPGbQ")
    #expect(await waitFor { latest.state.playback?.inReview == false })
    await backend.disconnect()
}

@Test func liveTakesTheCamerasOwnScreenOffItsPlaybackPage() async throws {
    // An ALEXA Mini: PlayBackEnd alone left its screen on the playback page, "No clip selected", until REC.
    // Live sends the PlayBackEnd its page's exit does, not the LOCK button's that sorts first, then GuiMode
    // NORMAL, as the page does.
    let fake = FakeArriCamera(extra: ["GuiMode": ["value": 0, "type": "enumint", "min": 0, "max": 3,
                                                  "properties": [3, 3, 3, 3], "readonly": 0]],
                              extraCommands: ["_1cxyMfk0EeaWP7LWENrtWw": "PlayBackEnd"])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.review))
    #expect(await waitFor { latest.state.playback?.isPlaying == true && fake.value("GuiMode") as? Int == 2 })
    await backend.send(.playback(.live))
    #expect(fake.calls.last?["command"] as? String == "_cCCFscHSEeStK8NH8ZPGbQ")
    #expect(await waitFor { fake.sets.last?["GuiMode"] as? Int == 0 }, "the screen back to NORMAL")
    #expect(await waitFor { latest.state.playback?.inReview == false })
    await backend.disconnect()
}

@Test func aScreenLeftOnItsPlaybackPageIsReviewAndLiveClearsIt() async throws {
    // What an earlier build's Live left: standby, nothing cued, the camera's screen still on its playback page. Tiles
    // shows review, so Live is there, and Live clears it.
    let gui: [String: Any] = ["value": 2, "type": "enumint", "min": 0, "max": 3, "properties": [3, 3, 3, 3], "readonly": 0]
    let fake = FakeArriCamera(extra: ["GuiMode": gui])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(await waitFor { latest.state.playback?.inReview == true })
    await backend.send(.playback(.live))
    #expect(await waitFor { fake.sets.last?["GuiMode"] as? Int == 0 })
    #expect(await waitFor { latest.state.playback?.inReview == false })
    await backend.disconnect()
}

@Test func cleanFeedIsEachSDIsImageSetting() async throws {
    // An ALEXA Mini's SDI 1/2 image: Clean is the camera's own clean feed. SDI 1 processed leaves SDI 2 clean only.
    func image(_ value: Int, _ flags: [Int]) -> [String: Any] {
        ["value": value, "type": "enumint", "min": 0, "max": 1, "properties": flags, "readonly": 0]
    }
    let fake = FakeArriCamera(extra: ["SDI1Processing": image(1, [3, 3]), "SDI2Processing": image(0, [3, 1])])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(await waitFor { latest.state.monitoring?.outputs.first { $0.id == "Sdi2" }?.overlays[.cleanFeed]?.isWritable == false })
    await backend.send(.setMonitorOverlay(.cleanFeed, true, output: "Sdi1"))
    #expect(fake.sets.last?["SDI1Processing"] as? Int == 0, "Clean")
    #expect(await waitFor { latest.state.monitoring?.outputs.first { $0.id == "Sdi1" }?.overlays[.cleanFeed]?.value == true })
    await backend.disconnect()
}

@Test func liveSaysWhenItCantTakeTheScreenOffItsPlaybackPage() async throws {
    // A body whose GuiMode is read-only: PlayBackEnd still goes, and the Activity Log says what to do on the camera.
    let gui: [String: Any] = ["value": 2, "type": "enumint", "min": 0, "max": 3, "properties": [3, 3, 3, 3], "readonly": 1]
    let fake = FakeArriCamera(extra: ["GuiMode": gui])
    try await fake.start()
    defer { fake.stop() }
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.live))
    #expect(fake.calls.last?["command"] as? String == "_cCCFscHSEeStK8NH8ZPGbQ")
    #expect(!fake.sets.contains { $0["GuiMode"] != nil })
    #expect(ActivityLog.shared.text.contains("\(fake.host): ARRI: playback ended, but the camera's screen can't be taken "
                                             + "off its playback page from here"))
    await backend.disconnect()
}

@Test func liveLeavesAMenuOnTheCamerasScreenAlone() async throws {
    let gui: [String: Any] = ["value": 1, "type": "enumint", "min": 0, "max": 3, "properties": [3, 3, 3, 3], "readonly": 0]
    let fake = FakeArriCamera(extra: ["GuiMode": gui])
    try await fake.start()
    defer { fake.stop() }
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.live))
    #expect(fake.calls.last?["command"] as? String == "_cCCFscHSEeStK8NH8ZPGbQ")
    try await Task.sleep(for: .milliseconds(300))
    #expect(!fake.sets.contains { $0["GuiMode"] != nil }, "OVERLAY_MENU isn't the playback page")
    await backend.disconnect()
}

@Test func reviewCuesTheCardAndPlays() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.review))
    #expect(fake.calls.map { $0["command"] as? String } == ["_EeUkIwIBEeSgptigTra4vQ", "_7q_F4cHREeStK8NH8ZPGbQ"],
            "PlayBackPrepare, then PlayBackGo")
    #expect(await waitFor { latest.state.playback?.isPlaying == true && latest.state.playback?.inReview == true })
    await backend.disconnect()
}

@Test func sessionIdIsKeptAcrossPolls() async throws {
    // The session id from all.cgi must be reused for every update.cgi poll — it is not a change counter.
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    let connectAllCgi = fake.allCgiCallCount
    fake.change("WBCurrentKelvin", 4300)
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 4300 })
    // A quiet period: no all.cgi calls, just update.cgi polls reusing the same id.
    try await Task.sleep(for: .milliseconds(400))
    #expect(fake.allCgiCallCount == connectAllCgi, "all.cgi not called again during quiet polling")
    let updatePaths = fake.paths.filter { $0.hasPrefix("/update.cgi?id=") }
    // All update polls must carry the same session id.
    let ids = Set(updatePaths.compactMap { $0.components(separatedBy: "id=").last })
    #expect(ids.count == 1, "every update.cgi poll reuses the same session id")
    await backend.disconnect()
}

@Test func invalidIdTriggersNewAllCgi() async throws {
    // When the camera says "Invalid id", the backend must call all.cgi again to open a new session.
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    let before = fake.allCgiCallCount
    fake.expireSession()
    // Trigger a change so the next poll returns (otherwise the session expiry arrives on the next poll after timeout).
    fake.change("WBCurrentKelvin", 3600)
    #expect(await waitFor(seconds: 8) { fake.allCgiCallCount > before }, "all.cgi called after Invalid id")
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 3600 }, "state recovered after new session")
    await backend.disconnect()
}

@Test func noAllCgiDuringQuietPeriod() async throws {
    // A quiet period (no camera changes) must not trigger all.cgi calls.
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    let after = fake.allCgiCallCount
    try await Task.sleep(for: .milliseconds(600))
    #expect(fake.allCgiCallCount == after, "no all.cgi during a quiet period with working update.cgi")
    await backend.disconnect()
}

@Test func emptyChangeListsAreQuietNotBroken() async throws {
    // A camera with nothing moving answers {"id", "variables": {}} each time its own wait runs out: a normal answer,
    // so the long poll stays (no fallback to reading all.cgi).
    let fake = FakeArriCamera(config: .init(longPollSeconds: 0.05))
    try await fake.start()
    defer { fake.stop() }
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    let after = fake.allCgiCallCount
    try await Task.sleep(for: .milliseconds(1200))
    #expect(fake.allCgiCallCount == after, "a dozen empty answers aren't a reason to read all.cgi")
    await backend.disconnect()
}

@Test func noAllCgiOnRecStartWhenAnswerCarriesFields() async throws {
    // When update answers carry type/min/max/readonly (as the Mini does), no all.cgi re-read is needed on REC.
    // The fake sends full variable dicts in nested mode, so readonly changes arrive in the update answer.
    let fake = FakeArriCamera(config: .init(recDelay: 0.1))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    let before = fake.allCgiCallCount
    await backend.send(.record(true))
    #expect(await waitFor { latest.state.recording.state == .recording })
    // FPSNominal's readonly flag arrives in the REC update (fake sends full variable dicts): no all.cgi needed.
    #expect(fake.allCgiCallCount == before, "no all.cgi on REC start when update answers carry field metadata")
    await backend.send(.record(false))
    #expect(await waitFor { latest.state.recording.state == .idle })
    #expect(fake.allCgiCallCount == before, "no all.cgi on REC stop either")
    await backend.disconnect()
}

@Test func minMaxReadonlyChangesAppliedViaUpdate() async throws {
    // FPSNominal max and ShutterNominal readonly arrive in update answers and must be merged into the reading.
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    // Simulate the camera narrowing FPSNominal's max (format change) and making ShutterNominal read-only.
    fake.changeField("FPSNominal", field: "max", value: 30.0)
    fake.changeField("ShutterNominal", field: "readonly", value: 1)
    #expect(await waitFor { latest.state.frameRate?.project.options.contains("200") == false },
            "FPSNominal max 30 applied: 200 fps no longer offered")
    #expect(await waitFor { latest.state.shutterAngle?.isWritable == false },
            "ShutterNominal readonly applied via update")
    await backend.disconnect()
}

@Test func playbackPrepareForMiniCardB() async throws {
    // When a snapshot has PlaybackMediumActive = Card B (index 2), the Mini's card-B command id and
    // _TableVersion_Local payload are used.
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    // Add PlaybackMediumActive and the card-B PlayBackPrepare id to the fake.
    fake.setVariable("PlaybackMediumActive", ["value": 2, "type": "enumint", "min": 0, "max": 2, "readonly": 1,
                                               "properties": [3, 3, 3]])
    fake.setVariable("ClipCountCardB", ["value": 5, "type": "int", "readonly": 1])
    fake.addCommand("_EeUkLAIBEeSgptigTra4vQ", name: "PlayBackPrepare")
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.playback(.play))
    let prepare = try #require(fake.calls.first)
    #expect(prepare["command"] as? String == "_EeUkIwIBEeSgptigTra4vQ", "card B uses _EeUkIwIBEeSgptigTra4vQ")
    let set = prepare["set"] as? [String: Any]
    #expect(set?["_TableVersion_Local"] != nil, "payload carries _TableVersion_Local")
    #expect(set?["PlaybackMediumSelected_Local"] == nil, "Mini payload: no PlaybackMediumSelected_Local")
    await backend.disconnect()
}

@Test func withoutTheLongPollItReadsAllCgi() async throws {
    let fake = FakeArriCamera(config: .init(update: .missing))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake) { await $0.configure(pollInterval: 0.2) }
    defer { listening.cancel() }
    fake.change("WBCurrentKelvin", 4300)
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 4300 })
    let asked = fake.paths.filter { $0.hasPrefix("/update.cgi") }.count
    try await Task.sleep(for: .milliseconds(500))
    #expect(fake.paths.filter { $0.hasPrefix("/update.cgi") }.count == asked, "asked once, then not again")
    await backend.disconnect()
}

@Test func aCounterWithoutChangesMeansReadEverything() async throws {
    let fake = FakeArriCamera(config: .init(update: .counterOnly))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    let reads = fake.paths.filter { $0 == "/all.cgi" }.count
    fake.change("WBCurrentKelvin", 3600)
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 3600 })
    #expect(fake.paths.filter { $0 == "/all.cgi" }.count > reads, "the change was fetched with all.cgi")
    await backend.disconnect()
}

@Test func recWithAStateItCantReadIsTrustedOnAcceptance() async throws {
    // No page script: CameraState is a bare number, so Tiles can't tell recording from playback by it.
    let fake = FakeArriCamera(config: .init(servesScript: false, recDelay: 0.05))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.record(true))
    #expect(await waitFor { latest.state.recording.state == .recording }, "accepted, and nothing says otherwise")
    #expect(latest.state.takeStartedAt != nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(latest.state.recording.state == .recording, "an unreadable state doesn't flip it back")
    await backend.send(.record(false))
    #expect(fake.calls.last?["command"] as? String == ArriFixture.recStop, "so it can still be stopped")
    #expect(await waitFor { latest.state.recording.state == .idle })
    await backend.disconnect()
}

@Test func aSecondRecTapWhileTheFirstIsPendingSendsNothing() async throws {
    let fake = FakeArriCamera(config: .init(recDelay: 0.4))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    async let first: Void = backend.send(.record(true))
    try await Task.sleep(for: .milliseconds(100))
    async let second: Void = backend.send(.record(true))
    _ = await (first, second)
    #expect(fake.calls.filter { $0["command"] as? String == ArriFixture.recStart }.count == 1)
    #expect(await waitFor { latest.state.recording.state == .recording })
    await backend.disconnect()
}

@Test func flatUpdatesAreReadToo() async throws {
    let fake = FakeArriCamera(config: .init(update: .flat))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    fake.change("ShutterNominal", 90.0)
    #expect(await waitFor { latest.state.shutterAngle?.value == 90 })
    await backend.disconnect()
}

@Test func theScriptIsKeptAndRevalidated() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("arri-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cache) }
    let (first, _, l1) = try await connected(fake, cache: cache)
    await first.disconnect()
    l1.cancel()
    let (second, latest, l2) = try await connected(fake, cache: cache)
    defer { l2.cancel() }
    #expect(fake.scriptBodiesServed == 1)
    #expect(fake.notModifiedAnswers == 1, "the second connection got a 304")
    #expect(latest.state.nd?.preset.options == ["Clear", "0.6", "1.2", "2.1"], "labels from the kept script")
    await second.disconnect()
}

@Test func withoutTheScriptTilesTablesStandIn() async throws {
    let fake = FakeArriCamera(config: .init(servesScript: false))
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(latest.state.iso?.value == 800)
    #expect(latest.state.nd?.preset.value == "0.6")
    await backend.disconnect()
}

@Test func aCameraThatGoesAwayFailsTheLink() async throws {
    let fake = FakeArriCamera(config: .init(longPollSeconds: 0.2))
    try await fake.start()
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    fake.stop()
    #expect(await waitFor(seconds: 8) { if case .failed = latest.state.connection { return true }; return false })
    await backend.disconnect()
}

@Test func probeKnowsAnArriWebRemote() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    #expect(await ArriRemoteProbe.probe(host: fake.host) == .arri(model: "ALEXA Mini"))
}

// MARK: - The page and the demo

@Test func arriDemoOffersEveryTileOnItsPage() {
    for body in [MockBody.alexaMini, .alexaMiniLF, .alexa35] {
        let sample = MockCameraBackend.arriSampleState(body: body)
        let missing = LayoutTemplates.arriCells.map(\.0).filter { !sample.offers($0) && $0 != .haLow }
        #expect(missing.isEmpty, "\(body) demo lacks \(missing)")
    }
    #expect(MockCameraBackend.arriSampleState(body: .alexaMiniLF).nd?.preset.options == ["Clear", "0.6", "1.2", "1.8"])
    #expect(MockCameraBackend.arriSampleState(body: .alexa35).iso?.options.last == 6400)
    #expect(MockCameraBackend.arriSampleState(body: .alexaMini).monitoring?.outputs.map(\.name) == ["SDI 1", "SDI 2", "EVF"])
}

@Test func arriGetsItsOwnBlock() {
    let sample = MockCameraBackend.arriSampleState()
    let profile = CameraProfile(model: sample.model, offered: Set(WidgetKind.allCases.filter { sample.offers($0) }),
                                make: .arri)
    let kinds = Set(LayoutTemplates.block(camera: UUID(), profile: profile, wide: true).map(\.kind))
    for kind in [WidgetKind.zebra, .focusAssist, .frameGuides, .playback, .lut, .desqueeze] {
        #expect(kinds.contains(kind), "\(kind) missing from the ARRI page")
    }
    #expect(MeshDeviceList.cameraMaker(hostname: nil, mac: "84:90:00:1a:2b:3c") == .arri)
}

@Test func arriDemoChangesWhatTheTilesChange() async throws {
    let backend = MockCameraBackend(state: MockCameraBackend.arriSampleState(), label: "A", latency: .milliseconds(1),
                                    heartbeat: nil)
    let latest = Latest()
    let listening = Task { for await s in backend.updates { latest.set(s) } }
    defer { listening.cancel() }
    await backend.connect()
    await backend.send(.setKelvin(3200))
    await backend.send(.setNDPreset("2.1"))
    await backend.send(.setFrameRate("48"))
    await backend.send(.setMonitorOverlay(.zebra, true, output: "Evf"))
    await backend.send(.setShutterMode(.speed))
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.shown == 3200 })
    #expect(latest.state.nd?.preset.shown == "2.1")
    #expect(latest.state.frameRate?.project.shown == "48")
    #expect(latest.state.monitoring?.outputs.first { $0.id == "Evf" }?.overlays[.zebra]?.value == true)
    #expect(latest.state.shutterAngle != nil && latest.state.shutterSpeed != nil, "ARRI keeps both angle and time")
}

@Test func cameraComesBackAfterSoftwareReload() async throws {
    // Connect, send setResolution("16:9 HD"), expect: stale, then connected within a few seconds,
    // resolution reported as 16:9 HD, and a subsequent command is acted on.
    let mode: [String: Any] = ["value": 0, "type": "enumint", "min": 0, "max": 2, "properties": [3, 3, 3], "readonly": 0]
    let prepCount: [String: Any] = ["value": 0, "type": "int", "readonly": 1]
    let prepReload: [String: Any] = ["value": false, "type": "bool", "readonly": 1]
    let restarting: [String: Any] = ["value": false, "type": "bool", "readonly": 1]
    var cfg = FakeArriCamera.Config()
    cfg.reloads = ["SensorMode"]
    cfg.longPollSeconds = 0.3
    let fake = FakeArriCamera(
        config: cfg,
        extra: [
            "SensorModePrepare": mode,
            "PrepareCommandResultCount": prepCount,
            "PrepareCommandFWWillReload": prepReload,
            "SystemSoftwareIsRestarting": restarting,
        ],
        extraCommands: ["_GnbMUFfSEeWK7Pu_oST6Ew": "SensorFormatPrep"]
    )
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.setResolution("16:9 HD"))
    // State must go stale during the reload.
    #expect(await waitFor(seconds: 4) { latest.state.connection == .stale }, "stale during reload")
    // Then recover to connected within a few seconds.
    #expect(await waitFor(seconds: 8) { latest.state.connection == .connected }, "back to connected after reload")
    // Resolution reported by the camera's own reading.
    #expect(latest.state.resolution?.value == "16:9 HD", "resolution updated after reload")
    // Commands after recovery must be acted on.
    let setsBefore = fake.sets.count
    await backend.send(.setISO(1600))
    #expect(await waitFor { fake.sets.count > setsBefore }, "command after reload is sent to camera")
    await backend.disconnect()
}

@Test func setOutputFollowsWritesSDI2IsSDI1Clone() async throws {
    // Sending .setOutputFollows(false, output: "Sdi2") must write SDI2IsSDI1Clone: false to the camera.
    let cloneVar: [String: Any] = ["value": true, "type": "bool", "readonly": 0]
    let image: [String: Any] = ["value": 1, "type": "enumint", "min": 0, "max": 1, "properties": [3, 3], "readonly": 0]
    let fake = FakeArriCamera(extra: [
        "SDI2IsSDI1Clone": cloneVar,
        "SDI1Processing": image,
        "SDI2Processing": image,
    ])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    // The clone is on at connect: Sdi2 should follow Sdi1.
    #expect(await waitFor { latest.state.monitoring?.outputs.first { $0.id == "Sdi2" }?.follows == "Sdi1" })
    await backend.send(.setOutputFollows(false, output: "Sdi2"))
    #expect(fake.sets.last?["SDI2IsSDI1Clone"] as? Bool == false, "turning the clone off writes the variable")
    await backend.disconnect()
}

@Test func anEveryOutputSwitchLeavesACloneToFollow() async throws {
    // The Clean Feed tile (every output) while SDI 2 clones SDI 1: only SDI 1 is written; SDI 2 follows it.
    let image: [String: Any] = ["value": 1, "type": "enumint", "min": 0, "max": 1, "properties": [3, 3], "readonly": 0]
    let fake = FakeArriCamera(extra: ["SDI2IsSDI1Clone": ["value": true, "type": "bool", "readonly": 0],
                                      "SDI1Processing": image, "SDI2Processing": image])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(await waitFor { latest.state.monitoring?.outputs.first { $0.id == "Sdi2" }?.follows == "Sdi1" })
    await backend.send(.setMonitorOverlay(.cleanFeed, true, output: nil))
    #expect(fake.sets.last?["SDI1Processing"] as? Int == 0)
    #expect(fake.sets.last?["SDI2Processing"] == nil, "SDI 2 follows SDI 1 on the camera")
    await backend.disconnect()
}

@Test func sensorFormatChangesAsTheMinisPageDoes() async throws {
    // A camera with a …Prepare twin (an ALEXA Mini): the prepare command with the target first, then the value; the
    // picker asked before, since the camera reloads its software.
    let mode: [String: Any] = ["value": 0, "type": "enumint", "min": 0, "max": 2, "properties": [3, 3, 3], "readonly": 0]
    let fake = FakeArriCamera(extra: ["SensorModePrepare": mode], extraCommands: ["_GnbMUFfSEeWK7Pu_oST6Ew": "SensorFormatPrep"])
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(latest.state.resolution?.restartRequired == ["4:3 2.8K", "16:9 HD"])
    await backend.send(.setResolution("16:9 HD"))
    #expect(await waitFor { fake.sets.contains { ($0["SensorMode"] as? Int) == 2 } }, "the value, after the prepare")
    let call = fake.calls.first { ($0["command"] as? String) == "_GnbMUFfSEeWK7Pu_oST6Ew" }
    #expect((call?["set"] as? [String: Any])?["SensorModePrepare"] as? Int == 2)
    await backend.disconnect()
}

/// A camera that doesn't split its reel by card reads and writes the generic one (`reelField`; the Mini's is its card's).
@Test func genericReelIsReadAndWrittenThere() throws {
    #expect(try fixtureReading().reelField == ArriField.reel)
}

/// Off right after on: the camera's reading doesn't have the on yet, and the off was left as if zebra were off there,
/// so zebra stayed on. A write still on its way counts.
@Test func zebraOffJustAfterOnIsSent() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, _, listening) = try await connected(fake)
    defer { listening.cancel() }
    await backend.send(.setMonitorOverlay(.zebra, true, output: "Evf"))
    #expect(fake.sets.last?["ExposureToolEvf"] as? Int == 2)
    await backend.send(.setMonitorOverlay(.zebra, false, output: "Evf"))
    #expect(fake.sets.last?["ExposureToolEvf"] as? Int == 0)
    await backend.disconnect()
}

/// The Clips window on an ALEXA: cued first (PlayBackPrepare), then PlayBackSkipClip a clip at a time
/// to the one picked, by the index a fresh read gives, then PlayBackGo. From the commands a Mini's page sends; never run
/// on one.
@Test func aClipPickedFromTheListIsSkippedToAndPlayed() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(latest.state.offers(.clips))
    await backend.send(.playback(.goToClip(4)))
    let commands = fake.calls.compactMap { $0["command"] as? String }
    #expect(commands == ["_EeUkIwIBEeSgptigTra4vQ"] + Array(repeating: ArriFixture.skipForward, count: 4)
            + ["_7q_F4cHREeStK8NH8ZPGbQ"], "PlayBackPrepare, four skips on, PlayBackGo")
    #expect(fake.value("PlaybackClipIndex") as? Int == 4)
    #expect(await waitFor { latest.state.playback?.clipNumber == 5 && latest.state.playback?.isPlaying == true })
    // Cued already: back from there, no PlayBackPrepare.
    await backend.send(.playback(.goToClip(1)))
    #expect(fake.value("PlaybackClipIndex") as? Int == 1)
    #expect(fake.calls.compactMap { $0["command"] as? String }.filter { $0 == "_EeUkIwIBEeSgptigTra4vQ" }.count == 1)
    await backend.disconnect()
}

/// Auto white balance on an ALEXA: "AWB" among the presets where the camera has the command,
/// and picking it runs the page's own AWB button's; the Kelvin it measured follows.
@Test func autoWhiteBalanceRunsThePagesCommand() async throws {
    let fake = FakeArriCamera()
    try await fake.start()
    defer { fake.stop() }
    let (backend, latest, listening) = try await connected(fake)
    defer { listening.cancel() }
    #expect(latest.state.whiteBalance?.preset.options.last == "AWB")
    await backend.send(.setWhiteBalancePreset("AWB"))
    #expect(fake.calls.last?["command"] as? String == "_4da_Ua3pEeSjhp9JjGKhGQ")
    #expect(await waitFor { latest.state.whiteBalance?.kelvin.value == 4870 })
    await backend.disconnect()
}

