import Foundation
import Testing
@testable import CameraCore
import CameraKitTestSupport

@Test func choiceStepsStopAtTheEnds() {
    let options = ["Clear", "1/4", "1/16"]
    #expect(Choice("Clear", options: options).option(offsetBy: 1) == "1/4")
    #expect(Choice("Clear", options: options).option(offsetBy: -1) == nil)
    #expect(Choice("1/16", options: options).option(offsetBy: 1) == nil)
    #expect(Choice("1/4", options: options, pending: "1/16").option(offsetBy: -1) == "1/4")
}

@Test func levelSnapsToStepAndClamps() {
    let kelvin = Level(6000, range: 2500...9900, step: 100)
    #expect(kelvin.value(atFraction: 0) == 2500)
    #expect(kelvin.value(atFraction: 1) == 9900)
    #expect(kelvin.value(atFraction: 1.4) == 9900)
    #expect(kelvin.value(atFraction: 0.473) == 6000)
}

@Test func sliderResetPositionsLandExactlyOnTheirValues() {
    let tint = Level(12, range: -99...99, step: 1)
    #expect(tint.fraction(for: 0) == 0.5)
    #expect(tint.value(atFraction: tint.fraction(for: 0)) == 0)
    let kelvin = Level(6000, range: 2500...9900, step: 100)
    #expect(kelvin.value(atFraction: kelvin.fraction(for: 5600)) == 5600)
}

@Test func timecodeRunsFromItsAnchor() {
    let anchor = Date(timeIntervalSince1970: 0)
    let clock = TimecodeClock(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: 24, fps: 24, anchor: anchor, isRunning: true)
    #expect(clock.string(at: anchor) == "01:00:00:00")
    #expect(clock.string(at: anchor.addingTimeInterval(1.5)) == "01:00:01:12")
}

@Test func stoppedTimecodeHolds() {
    let anchor = Date(timeIntervalSince1970: 0)
    let clock = TimecodeClock(hours: 23, minutes: 59, seconds: 59, frames: 23, rate: 24, fps: 24, anchor: anchor, isRunning: false)
    #expect(clock.string(at: anchor.addingTimeInterval(60)) == "23:59:59:23")
}

// MARK: - TC Run mode behavior (D0D3 never advances over PTP)

@Test func freeRunTicksEvenWhenNotRecording() {
    // In Free Run mode the clock must advance regardless of recording state.
    let anchor = Date(timeIntervalSince1970: 0)
    let clock = TimecodeClock(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: 24, fps: 24, anchor: anchor, isRunning: true)
    #expect(clock.string(at: anchor.addingTimeInterval(2.0)) == "01:00:02:00")
}

@Test func recRunHoldsWhenNotRecording() {
    // In Rec Run mode, a clock with isRunning=false must hold.
    let anchor = Date(timeIntervalSince1970: 0)
    let clock = TimecodeClock(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: 24, fps: 24, anchor: anchor, isRunning: false)
    #expect(clock.string(at: anchor.addingTimeInterval(2.0)) == "01:00:00:00")
}

@Test func mockRecordStartSetsTakeStartedAt() async {
    let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    var updates = backend.updates.makeAsyncIterator()
    await backend.connect()
    _ = await updates.next()  // connecting
    let connected = await updates.next()
    #expect(connected?.takeStartedAt == nil)

    let before = Date()
    let press = Task { await backend.send(.record(true)) }
    _ = await updates.next()  // pending
    let confirmed = await updates.next()
    let after = Date()
    #expect(confirmed?.recording.state == .recording)
    #expect(confirmed?.takeStartedAt != nil)
    if let t = confirmed?.takeStartedAt {
        #expect(t >= before && t <= after)
    }
    await press.value

    let stopTask = Task { await backend.send(.record(false)) }
    _ = await updates.next()  // pending
    let stopped = await updates.next()
    #expect(stopped?.recording.state == .idle)
    #expect(stopped?.takeStartedAt == nil)
    await stopTask.value
}

@Test func timecodeWrapsAtMidnight() {
    let anchor = Date(timeIntervalSince1970: 0)
    let clock = TimecodeClock(hours: 23, minutes: 59, seconds: 59, frames: 23, rate: 24, fps: 24, anchor: anchor, isRunning: true)
    #expect(clock.string(at: anchor.addingTimeInterval(1.0 / 24.0 + 0.001)) == "00:00:00:00")
}

@Test func recordIsNeverOptimistic() async {
    let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    var updates = backend.updates.makeAsyncIterator()
    await backend.connect()
    _ = await updates.next()  // connecting
    let connected = await updates.next()
    #expect(connected?.recording.state == .idle)

    let press = Task { await backend.send(.record(true)) }
    let pending = await updates.next()
    #expect(pending?.recording.request == .start)
    #expect(pending?.recording.state == .idle, "REC must not show recording before the camera confirms")
    let confirmed = await updates.next()
    #expect(confirmed?.recording.state == .recording)
    #expect(confirmed?.recording.request == nil)
    await press.value
}

@Test func switchingBaseISOMovesTheISO() async {
    let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(1), connectDelay: .zero, heartbeat: nil)
    var updates = backend.updates.makeAsyncIterator()
    await backend.connect()
    _ = await updates.next()
    _ = await updates.next()
    await backend.send(.setBaseISO(12800))
    var last: CameraState?
    for _ in 0..<3 { last = await updates.next() }
    #expect(last?.baseISO?.value == 12800)
    #expect(last?.iso?.value == 12800)
    #expect(last?.iso?.options.contains(800) == false)
}

@Test func bodiesWithoutNDReportNoND() {
    #expect(MockCameraBackend.sampleState(body: .fx3).nd == nil)
    #expect(MockCameraBackend.sampleState(body: .fx6).nd != nil)
    #expect(MockCameraBackend.sampleState(body: .burano).modelName == "BURANO")
}

@MainActor @Test func newPageNamesItselfFromCameraLabels() {
    let store = DashboardStore.preview()
    let page = store.addPage(cameraIDs: store.cameras.prefix(2).map(\.id))
    #expect(page.name == "A+B")
    #expect(store.currentPage?.id == page.id)
    #expect(store.visibleCameras.map(\.slot.label) == ["A", "B"])
}

@MainActor @Test func setupSurvivesARelaunch() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = DashboardStore.load(from: defaults, startCameras: false)
    let added = first.addCamera(label: "E", color: .purple, host: "198.51.100.20", demoBody: .fx2)
    let solo = first.addPage(name: "Solo E", cameraIDs: [added.id])

    let second = DashboardStore.load(from: defaults, startCameras: false)
    #expect(second.cameras.map(\.slot.label) == ["E"])       // a new install starts empty
    #expect(second.currentPage?.id == solo.id)
    #expect(second.visibleCameras.map(\.slot.host) == ["198.51.100.20"])
    #expect(second.savedCamera(added.id)?.demoBody == .fx2)
}

@MainActor @Test func removingACameraTakesItOffEveryPage() {
    let store = DashboardStore.preview()
    let first = store.cameras[0].id
    store.removeCamera(first)
    #expect(store.cameras.count == 3)
    #expect(store.pages.allSatisfy { !$0.cameraIDs.contains(first) })
}

@Test func templatesStayInBoundsWithoutOverlaps() {
    for count in 1...5 {
        let ids = (0..<count).map { _ in UUID() }
        let layout = LayoutTemplates.materialize(cameraIDs: ids)
        #expect(layout.widgets.allSatisfy { layout.fits($0) }, "\(count) cameras")
        #expect(layout.cameraIDs == ids)
        #expect(layout.columns == count * (count <= 2 ? 4 : 2))
    }
}

/// An automatic page is laid out again on every redraw. The same tiles must come back with the same IDs, or SwiftUI
/// rebuilds every tile whenever a camera reports (an open picker closed under the finger on iPad).
@Test func automaticLayoutsKeepTheirTileIDs() {
    let ids = [UUID(), UUID()]
    let first = LayoutTemplates.materialize(cameraIDs: ids)
    let again = LayoutTemplates.materialize(cameraIDs: ids)
    #expect(first.widgets.map(\.id) == again.widgets.map(\.id))
    #expect(Set(first.widgets.map(\.id)).count == first.widgets.count)
    // A page saved from that layout, given the same camera's block again, still has no duplicate IDs.
    let appended = LayoutTemplates.appendingBlock(for: ids[0], to: first)
    #expect(Set(appended.widgets.map(\.id)).count == appended.widgets.count)
}

@Test func compactKeepsStackedHalfTilesTogether() throws {
    let camera = UUID()
    let wide = PageLayout(columns: 4, widgets: LayoutTemplates.wide(camera: camera))
    let compact = LayoutTemplates.compact(wide, camera: camera)
    #expect(compact.columns == 2)
    #expect(compact.widgets.count == wide.widgets.count)
    #expect(compact.widgets.allSatisfy { compact.fits($0) })
    let timecode = try #require(compact.widgets.first { $0.kind == .timecode })
    let clip = try #require(compact.widgets.first { $0.kind == .clipName })
    let latency = try #require(compact.widgets.first { $0.kind == .latency })
    #expect(timecode.x == clip.x && clip.y == timecode.y + 1)
    #expect(latency.y == timecode.y && latency.x != timecode.x)  // the stack sits beside latency
}

@Test func phoneReadsNameAndInfoThenTimecodeAndLatency() throws {
    let camera = UUID()
    let fx3 = LayoutTemplates.compact(PageLayout(columns: 4, widgets: LayoutTemplates.fx3(camera: camera)), camera: camera)
    let narrow = PageLayout(columns: 2, widgets: LayoutTemplates.narrow(camera: camera))
    for layout in [fx3, narrow] {
        func tile(_ kind: WidgetKind) throws -> PageWidget { try #require(layout.widgets.first { $0.kind == kind }) }
        #expect(try tile(.label).y == 0 && tile(.label).x == 0)
        // Battery and Media are the identity strip's camera-info tiles (column 1, stacked in one 2-half-row span)
        #expect(try tile(.battery).y == 0 && tile(.battery).x == 1)
        #expect(try tile(.media).y == 1 && tile(.media).x == 1)
        #expect(try tile(.timecode).y == tile(.label).maxY && tile(.timecode).x == 0)
        #expect(try tile(.latency).y == tile(.timecode).y && tile(.latency).x == 1)
    }
}

@Test func compactFX3PageReadsLikeTheBigOne() throws {
    let camera = UUID()
    let wide = PageLayout(columns: LayoutTemplates.wideColumns, widgets: LayoutTemplates.fx3(camera: camera))
    let compact = LayoutTemplates.compact(wide, camera: camera)
    #expect(compact.columns == 2)
    #expect(compact.widgets.count == wide.widgets.count)
    #expect(compact.widgets.allSatisfy { compact.fits($0) })
    func y(_ kind: WidgetKind) throws -> Int { try #require(compact.widgets.first { $0.kind == kind }).y }
    let exposure = try [WidgetKind.record, .iso, .shutterDial, .shutterValue, .wbPreset].map(y)
    // Exposure stays one block above white balance, then iris, then format, then look and focus.
    #expect(try exposure.max()! < y(.wbSliders))
    #expect(try y(.wbSliders) < y(.iris))
    #expect(try y(.iris) < y(.frameRate))
    #expect(try y(.frameRate) <= y(.codec) && y(.codec) < y(.bitrate))
    #expect(try y(.bitrate) < y(.lut) && y(.lut) < y(.focusMode))
    // Every identity tile is a full row high on a phone except battery and media, which stack as a pair.
    func h(_ kind: WidgetKind) throws -> Int { try #require(compact.widgets.first { $0.kind == kind }).h }
    #expect(try h(.battery) == 1 && h(.media) == 1 && h(.latency) == 2 && h(.timecode) == 2)
    // Battery directly above media in the identity strip.
    #expect(compact.widgets.first { $0.kind == .battery }.map { [$0.x, $0.y] }
            == compact.widgets.first { $0.kind == .media }.map { [$0.x, $0.y - 1] })
    #expect(try h(.bitrate) == 1 && h(.clipName) == 1 && y(.clipName) == y(.bitrate) + 1)
}

@Test func automaticBlockClosesGapsWithoutReshuffling() throws {
    let camera = UUID()
    let wide = LayoutTemplates.wide(camera: camera)
    // A Sony body: no dynamic range, and no outputs' LUT, false color or monitoring either.
    let lacking: Set<WidgetKind> = [.ndPreset, .ndMinus, .ndPlus, .clipName, .resolution, .desqueeze, .dynamicRange,
                                    .viewAssist, .falseColor, .monitoring]
    let kept = LayoutTemplates.closingGaps(in: wide, keeping: { !lacking.contains($0.kind) }, columns: 4, x: 0)
    let layout = PageLayout(columns: 4, widgets: kept)
    #expect(kept.count == wide.count - lacking.count)
    #expect(kept.allSatisfy { layout.fits($0) })
    func tile(_ kind: WidgetKind) throws -> PageWidget { try #require(kept.first { $0.kind == kind }) }
    #expect(try tile(.timecode).h == 2)                          // lost its clip-name partner: fills the stack
    #expect(try tile(.latency).x == 3)                           // the identity strip keeps its order
    #expect(try tile(.frameRate).x == 0 && tile(.frameRate).w == 4)  // ND and its − + gone: frame rate takes the row
    #expect(try tile(.codec).x == 0 && tile(.codec).w == 2)          // the strip that kept its tiles stays as it was
    #expect(try tile(.bitrate).x == 2 && tile(.bitrate).y == tile(.codec).y)
    #expect(layout.rows == wide.map(\.maxY).max()! - 3)         // the resolution strip and the outputs' strip went
}

@Test func closingGapsOnASavedPageStaysInsideEachCamera() throws {
    let a = UUID(), b = UUID()
    let page = PageLayout(columns: 8, widgets: LayoutTemplates.wide(camera: a) + LayoutTemplates.wide(camera: b, x: 4))
    let closed = LayoutTemplates.closingGaps(in: page) { $0.cameraID == a || ![.ndPreset, .desqueeze].contains($0.kind) }
    #expect(closed.widgets.allSatisfy { closed.fits($0) })
    #expect(closed.widgets.filter { $0.cameraID == a }.allSatisfy { $0.maxX <= 4 })
    #expect(closed.widgets.filter { $0.cameraID == b }.allSatisfy { $0.x >= 4 })
    #expect(closed.widgets.filter { $0.cameraID == a }.count == LayoutTemplates.wide(camera: a).count)
}

@MainActor @Test func overlappingMoveIsRejected() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    let before = try #require(store.currentPage?.layout)
    var moved = before.widgets[0]
    moved.x = before.widgets[1].x
    moved.y = before.widgets[1].y
    #expect(store.placeWidget(page, moved) == false)
    #expect(store.currentPage?.layout == before)
}

@MainActor @Test func cameraAddedToCustomisedPageGetsABlockUnderneath() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    let rowsBefore = try #require(store.currentPage?.layout?.rows)
    let added = store.addCamera(label: "E", color: .purple, host: "", demoBody: .fx2)
    let layout = try #require(store.currentPage?.layout)
    #expect(layout.cameraIDs.contains(added.id))
    #expect(layout.widgets.filter { $0.cameraID == added.id }.allSatisfy { $0.y >= rowsBefore })
    #expect(store.visibleCameras.map(\.slot.label) == ["A", "B", "E"])
}

@Test func unknownTileKindsAreDroppedNotFatal() throws {
    let layout = PageLayout(columns: 2, widgets: [PageWidget(kind: .iso, cameraID: UUID(), x: 0, y: 0, w: 2, h: 4)])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any])
    var widgets = try #require(object["widgets"] as? [[String: Any]])
    var future = widgets[0]
    future["kind"] = "hologram"
    future["id"] = UUID().uuidString
    widgets.append(future)
    object["widgets"] = widgets
    let decoded = try JSONDecoder().decode(PageLayout.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.widgets.map(\.kind) == [.iso])
}

@Test func camerasSavedBeforeConnectionsDecodeAsDemos() throws {
    let legacy = #"{"slot":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"A","color":"red","host":"198.51.100.16"},"demoBody":"MPC-2610"}"#
    let camera = try JSONDecoder().decode(SavedCamera.self, from: Data(legacy.utf8))
    #expect(camera.connection == .demo(.burano))
    let roundTrip = try JSONDecoder().decode(SavedCamera.self, from: JSONEncoder().encode(camera))
    #expect(roundTrip == camera)
}

@MainActor @Test func passwordsLiveInTheCredentialStoreNotTheSavedSetup() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = InMemoryCredentialStore()
    let store = DashboardStore.load(from: defaults, startCameras: false, credentials: credentials)
    let camera = store.addCamera(label: "F", color: .teal, host: "192.0.2.203",
                                 connection: .sony(SonyConnection(username: "TW")), password: "secret")
    #expect(credentials.password(for: camera.id) == "secret")
    let saved = String(decoding: try #require(defaults.data(forKey: "dashboard.v1")), as: UTF8.self)
    #expect(!saved.contains("secret"))
    store.removeCamera(camera.id)
    #expect(credentials.password(for: camera.id) == nil)
}

@MainActor @Test func firstFingerprintIsSavedWithoutAskingAndNeverOverwritten() {
    let store = DashboardStore.preview()
    let camera = store.addCamera(label: "F", color: .teal, host: "192.0.2.203",
                                 connection: .sony(SonyConnection(username: "TW")), password: "secret")
    store.rememberFingerprint("SHA256:first", for: camera.id)
    store.rememberFingerprint("SHA256:imposter", for: camera.id)
    #expect(store.savedCamera(camera.id)?.connection.sony?.trustedFingerprint == "SHA256:first")
}

@MainActor @Test func trustingAFingerprintSavesIt() throws {
    let store = DashboardStore.preview()
    let camera = store.addCamera(label: "F", color: .teal, host: "192.0.2.203",
                                 connection: .sony(SonyConnection(username: "TW")), password: "secret")
    store.trustFingerprint("SHA256:abc", for: camera.id)
    #expect(store.savedCamera(camera.id)?.connection.sony?.trustedFingerprint == "SHA256:abc")
}

@MainActor @Test func reorderingCamerasReordersAutomaticPages() {
    let store = DashboardStore.preview(page: "A+B")
    store.moveCameras(fromOffsets: IndexSet(integer: 1), toOffset: 0)   // B before A
    #expect(store.cameras.map(\.slot.label) == ["B", "A", "C", "D"])
    #expect(store.visibleCameras.map(\.slot.label) == ["B", "A"])
    store.movePage(store.pages[2].id, by: -1)
    #expect(store.pages.map(\.name) == ["All", "C", "A+B"])
}

@Test func commandsBelongToTheRightLinkGroups() {
    #expect(LinkKind(.setKelvin(5600)) == .whiteBalance)
    #expect(LinkKind(.setFrameRate("24")) == .frameRate)
    #expect(LinkKind(.setShutterAngle(180)) == .shutter)
    #expect(LinkKind(.record(true)) == .record)
    #expect(LinkKind(.setISO(800)) == nil)
}

@MainActor @Test func linkedWhiteBalanceFollowsAcrossThePage() async throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    for kind in LinkKind.allCases where kind != .whiteBalance { store.setLink(kind, enabled: false, on: page) }
    let a = store.cameras[0], b = store.cameras[1], c = store.cameras[2]
    for camera in [a, b, c] { camera.start() }
    // Wait for all three to connect.
    for _ in 0..<200 where !(a.state.connection == .connected && b.state.connection == .connected) {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    a.send(.setKelvin(4300))  // linking is off: b must not follow
    // Wait for a to confirm, then give enough time for a spurious follow to arrive.
    for _ in 0..<200 where a.state.whiteBalance?.kelvin.value != 4300 { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 50_000_000)  // negative check window ≤100 ms
    #expect(b.state.whiteBalance?.kelvin.value == 5600)
    store.setLinking(true, on: page)
    a.send(.setKelvin(3200))
    for _ in 0..<200 where b.state.whiteBalance?.kelvin.value != 3200 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(b.state.whiteBalance?.kelvin.value == 3200)
    #expect(c.state.whiteBalance?.kelvin.value == 5600)     // not on this page
    a.send(.setISO(800))
    // Wait for a to confirm, then verify b didn't follow (ISO isn't linkable).
    for _ in 0..<200 where a.state.iso?.value != 800 { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(b.state.iso?.value == 1600)
}

/// Who a linked command goes to (`linkedPeers`, which the fan-out and the frame rate tile's restart warning share): the
/// page's other cameras while it links that control; nobody while linking is off, for a control it doesn't link, or
/// from a camera that isn't on the page.
@MainActor @Test func linkedPeersAreThePagesOtherCamerasWhileItLinks() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let a = store.cameras[0], b = store.cameras[1], c = store.cameras[2]
    #expect(store.linkedPeers(of: a.id, for: .frameRate).isEmpty)
    store.setLinking(true, on: page)
    #expect(store.linkedPeers(of: a.id, for: .frameRate).map(\.id) == [b.id])
    #expect(store.linkedPeers(of: c.id, for: .frameRate).isEmpty)
    store.setLink(.frameRate, enabled: false, on: page)
    #expect(store.linkedPeers(of: a.id, for: .frameRate).isEmpty)
    #expect(store.linkedPeers(of: a.id, for: .record).map(\.id) == [b.id])
}

/// A demo page of several cameras of one kind (`-CCDebugDemoBodies`): each its own letter, its own clip names.
@MainActor @Test func demoBodiesMakeOnePageOfThoseCameras() throws {
    let store = DashboardStore.demoBodies("venice2,venice2,nonsense,alexaMini")
    #expect(store.cameras.map(\.slot.label) == ["A", "B", "C"])
    #expect(store.pages.map(\.name) == ["A+B+C"])
    #expect(MockCameraBackend.veniceSampleState(label: "B").clipName == "B005C003")
    #expect(MockCameraBackend.arriSampleState(label: "C").fileNaming?.cameraID?.value == "C")
}

@MainActor @Test func theLastPageCannotBeRemoved() {
    let store = DashboardStore.preview()
    for page in store.pages { store.removePage(page.id) }
    #expect(store.pages.count == 1)
}

// MARK: - FX3 template tests

@Test func fx3TemplateShape() {
    let camera = UUID()
    let layout = PageLayout(columns: LayoutTemplates.wideColumns,
                            widgets: LayoutTemplates.fx3(camera: camera))
    let kinds = Set(layout.widgets.map(\.kind))

    // In-bounds and non-overlapping.
    #expect(layout.widgets.allSatisfy { layout.fits($0) })
    #expect(layout.rows > 0)

    // Required tiles (resolution and de-squeeze are not exposed over the network protocol).
    let required: Set<WidgetKind> = [.label, .timecode, .record, .frameRate,
                                     .iso, .shutterDial, .shutterValue, .wbPreset, .wbSliders,
                                     .iris, .codec, .bitrate, .battery, .media, .latency,
                                     .lut, .focusMode]
    for kind in required { #expect(kinds.contains(kind), "FX3 layout missing \(kind)") }

    // Excluded tiles.
    let forbidden: Set<WidgetKind> = [.ndPreset, .ndMinus, .ndPlus, .sensorFlip, .colorBars, .webGUI,
                                      .resolution, .desqueeze]
    #expect(kinds.isDisjoint(with: forbidden))

    // Fits iPad landscape 1194×800 (minus 16 px padding, 8 px gaps).
    let w = 1194.0, h = 800.0, pad = 16.0, gap = 8.0
    let innerH = h - 2 * pad
    let cols = Double(layout.columns)
    let rows = Double(layout.rows)
    let cellWidth = (w - 2 * pad - (cols - 1) * gap) / cols
    let rowHeight = min(max((innerH - (rows - 1) * gap) / rows, 22), max(cellWidth * 0.6, 22))
    let contentH = rows * rowHeight + (rows - 1) * gap
    #expect(contentH <= innerH + 0.5, "FX3 template overflows iPad landscape (\(contentH) > \(innerH))")
}

@MainActor @Test func fx3AutoPageCreatedWhenFX3ModelReported() {
    var fx3State = MockCameraBackend.sampleState(body: .fx3, label: "X")
    fx3State.model = "ILME-FX3"
    let xSlot = CameraSlot(label: "X", color: .pink, host: "198.51.100.25")
    let cameras: [SavedCamera] = [SavedCamera(slot: xSlot, demoBody: .fx3),
                                  SavedCamera(slot: CameraSlot(label: "Y", color: .blue, host: "198.51.100.26"), demoBody: .fx6)]
    let pages: [CameraPage] = [CameraPage(name: "All", showsAllCameras: true)]
    let store = DashboardStore(cameras: cameras, pages: pages, startCameras: false,
                               initialStates: [xSlot.id: fx3State])
    let camera = store.cameras[0]
    let before = store.pages.count
    store.checkFX3AutoPage(for: camera)

    #expect(store.pages.count == before + 1)
    let newPage = store.pages.last
    #expect(newPage?.name == "X FX3")
    #expect(newPage?.layout == nil)  // automatic: drawn from the current FX3 block, never stale
    #expect(newPage?.cameraIDs == [camera.id])
}

@MainActor @Test func fx3AutoPageNotDuplicatedOnSubsequentUpdates() {
    var fx3State = MockCameraBackend.sampleState(body: .fx3, label: "X")
    fx3State.model = "ILME-FX3"
    let xSlot = CameraSlot(label: "X", color: .pink, host: "198.51.100.25")
    let cameras: [SavedCamera] = [SavedCamera(slot: xSlot, demoBody: .fx3),
                                  SavedCamera(slot: CameraSlot(label: "Y", color: .blue, host: "198.51.100.26"), demoBody: .fx6)]
    let pages: [CameraPage] = [CameraPage(name: "All", showsAllCameras: true)]
    let store = DashboardStore(cameras: cameras, pages: pages, startCameras: false,
                               initialStates: [xSlot.id: fx3State])
    let camera = store.cameras[0]
    store.checkFX3AutoPage(for: camera)
    let countAfterFirst = store.pages.count
    store.checkFX3AutoPage(for: camera)
    #expect(store.pages.count == countAfterFirst, "second call must not add another page")
}

@MainActor @Test func demoCPageUsesTheFX3Template() throws {
    let store = DashboardStore.preview(page: "C")
    #expect(try #require(store.currentPage).layout == nil, "the demo C page is automatic")
    let camera = store.cameras[2]
    // On a wide screen an automatic page draws the FX3's block, minus what the camera doesn't offer.
    let kinds = Set(LayoutTemplates.block(camera: camera.id, profile: camera.profile, wide: true).map(\.kind))
    #expect(kinds.isSuperset(of: [.frameRate, .codec, .bitrate, .lut, .focusMode, .record, .iso, .iris, .clipName]))
    #expect(kinds.isDisjoint(with: [.ndPreset, .resolution, .desqueeze, .sensorFlip, .webGUI]))
}

@MainActor @Test func versionOneLayoutsAreResetOnLoad() throws {
    let camera = SavedCamera(slot: CameraSlot(label: "C", color: .yellow, host: "x"), demoBody: .fx3)
    let stale = PageLayout(columns: 4, widgets: [PageWidget(kind: .desqueeze, cameraID: camera.slot.id, x: 0, y: 0, w: 2, h: 2)])
    let v1: [String: Any] = [
        "version": 1,
        "cameras": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(camera))],
        "pages": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CameraPage(name: "C", cameraIDs: [camera.slot.id], layout: stale)))],
    ]
    let defaults = try #require(UserDefaults(suiteName: "tw-cc-test-\(UUID().uuidString)"))
    defaults.set(try JSONSerialization.data(withJSONObject: v1), forKey: "dashboard.v1")
    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages.count == 1)
    #expect(store.pages[0].name == "C")
    #expect(store.pages[0].layout == nil)
}

@Test func linkedTileIndicatorLogic() {
    let linked: [(WidgetKind, LinkKind)] = [
        (.wbPreset, .whiteBalance), (.wbSliders, .whiteBalance),
        (.shutterDial, .shutter),   (.shutterValue, .shutter),
        (.frameRate,  .frameRate),  (.record,        .record),
    ]
    for (kind, expected) in linked { #expect(LinkKind.forWidget(kind) == expected) }

    let unlinked: [WidgetKind] = [.iso, .lut, .focusMode, .timecode]
    for kind in unlinked { #expect(LinkKind.forWidget(kind) == nil) }
}

// MARK: - Reconnect

/// Fails the first `failures` connects with a dropped link, then connects.
private actor FlakyBackend: CameraBackend {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation
    private var failures: Int
    private(set) var connects = 0

    init(failures: Int) {
        let stream = AsyncStream.makeStream(of: CameraState.self)
        updates = stream.stream
        continuation = stream.continuation
        self.failures = failures
    }

    func connect() async {
        connects += 1
        var state = CameraState()
        state.connection = failures > 0 ? .failed("link down") : .connected
        failures -= 1
        continuation.yield(state)
    }

    func disconnect() async {
        var state = CameraState()
        state.connection = .disconnected
        continuation.yield(state)
    }

    func send(_ command: CameraCommand) async {}
}

/// Sends whatever states a test gives it.
private actor ScriptedBackend: CameraBackend {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation

    init() {
        let stream = AsyncStream.makeStream(of: CameraState.self)
        updates = stream.stream
        continuation = stream.continuation
    }

    func push(_ connection: ConnectionState, latency: Int?) {
        var state = CameraState()
        state.connection = connection
        state.latencyMilliseconds = latency
        continuation.yield(state)
    }

    /// A state with this connection and recording (and the backend's own take start, where it times the take).
    func push(_ connection: ConnectionState, recording: RecordingState, request: RecordingControl.Request? = nil,
              startedAt: Date? = nil) {
        var state = CameraState()
        state.connection = connection
        state.recording = RecordingControl(state: recording, request: request)
        state.takeStartedAt = startedAt
        continuation.yield(state)
    }

    func connect() async {}
    func disconnect() async {}
    func send(_ command: CameraCommand) async {}
}

@MainActor @Test("Latency shows only for a connected camera, whatever the backend leaves in its state")
func latencyOnlyWhileConnected() async throws {
    let backend = ScriptedBackend()
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "test"), backend: backend)
    camera.start()
    defer { camera.disconnect() }
    func settle(_ connection: ConnectionState) async throws {
        for _ in 0..<500 where camera.state.connection != connection { try await Task.sleep(for: .milliseconds(10)) }
        #expect(camera.state.connection == connection)
    }

    await backend.push(.connected, latency: 42)
    try await settle(.connected)
    #expect(camera.state.latencyMilliseconds == 42)

    // The backend lost the link but kept its last average.
    for connection in [ConnectionState.failed("link down"), .connecting, .stale, .disconnected] {
        await backend.push(connection, latency: 42)
        try await settle(connection)
        #expect(camera.state.latencyMilliseconds == nil, "\(connection)")
    }
}

@MainActor @Test("Every take gets its REC time, whoever started it; one rolling before Tiles saw it has none")
func takeTimedWhoeverStartedIt() async throws {
    let backend = ScriptedBackend()
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "test"), backend: backend)
    camera.start()
    defer { camera.disconnect() }
    func settle(_ connection: ConnectionState, _ recording: RecordingState, request: RecordingControl.Request? = nil,
                startedAt: Date? = nil) async throws {
        await backend.push(connection, recording: recording, request: request, startedAt: startedAt)
        for _ in 0..<500 where camera.state.connection != connection || camera.state.recording.state != recording
            || camera.state.recording.request != request {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(camera.state.connection == connection && camera.state.recording.state == recording)
    }

    // Already rolling when Tiles first saw the camera: no start, rather than one made up.
    try await settle(.connected, .recording)
    #expect(camera.state.takeStartedAt == nil)

    // Stopped, then started at the camera: timed from when Tiles saw it start, and kept while it rolls.
    try await settle(.connected, .idle)
    try await settle(.connected, .recording)
    let seen = try #require(camera.state.takeStartedAt)
    #expect(abs(seen.timeIntervalSinceNow) < 2)
    try await settle(.connected, .recording)
    #expect(camera.state.takeStartedAt == seen)

    // The link drops mid-take and comes back with the camera still rolling: the same take, the same start.
    try await settle(.connecting, .unknown)
    #expect(camera.state.takeStartedAt == nil)
    try await settle(.connected, .recording)
    #expect(camera.state.takeStartedAt == seen)
    try await settle(.connected, .idle)
    #expect(camera.state.takeStartedAt == nil)

    // A start Tiles asked for is the backend's to time: nothing until the camera confirms, then the backend's.
    try await settle(.connected, .recording, request: .start)
    #expect(camera.state.takeStartedAt == nil)
    let confirmed = Date().addingTimeInterval(-0.25)
    try await settle(.connected, .recording, startedAt: confirmed)
    #expect(camera.state.takeStartedAt == confirmed)
    // A stop that timed out (the backend dropped its start) with the camera still rolling keeps the take's time.
    try await settle(.connected, .recording)
    #expect(camera.state.takeStartedAt == confirmed)

    // The link drops, and the camera stopped meanwhile and started again: that take wasn't seen starting.
    try await settle(.failed("link down"), .unknown)
    try await settle(.connected, .idle)
    try await settle(.connecting, .unknown)
    try await settle(.connected, .recording)
    #expect(camera.state.takeStartedAt == nil)
}

@MainActor private func waitUntilConnected(_ camera: CameraController) async throws {
    for _ in 0..<500 where camera.state.connection != .connected {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor @Test func cameraReconnectsAfterTheLinkDrops() async throws {
    let backend = FlakyBackend(failures: 2)
    // 10 ms initial retry so we don't wait 1 s + 2 s in tests.
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "test"),
                                  backend: backend, initialRetryDelay: 0.01)
    camera.start()
    try await waitUntilConnected(camera)
    #expect(camera.state.connection == .connected)
    #expect(await backend.connects == 3)  // the first try + 2 retries
}

@MainActor @Test func backgroundedCameraStaysDownUntilResumed() async throws {
    let backend = FlakyBackend(failures: 0)
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "test"),
                                  backend: backend, initialRetryDelay: 0.01)
    camera.start()
    try await waitUntilConnected(camera)
    camera.suspend()
    // Down first (under a loaded full run the 100 ms below wasn't always enough for the suspend to land: 2026-11-14),
    // then a brief wait, longer than the retry delay, so a spurious reconnect would show up.
    for _ in 0..<200 where camera.state.connection != .disconnected {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(camera.state.connection == .disconnected)
    #expect(await backend.connects == 1)
    camera.resume()
    try await waitUntilConnected(camera)
    #expect(camera.state.connection == .connected)
    #expect(await backend.connects == 2)
}

// MARK: - What a camera reported last time

@MainActor @Test func offlineCameraKeepsTheShapeItReportedLastTime() throws {
    let seen = CameraProfile(model: "ILME-FX3", offered: [.label, .record, .battery, .media, .iso, .lut])
    let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "test"),
                                  backend: FlakyBackend(failures: 0), lastSeen: seen)
    #expect(camera.offers(.iso))
    #expect(!camera.offers(.ndPreset))
    let block = LayoutTemplates.block(camera: camera.id, profile: camera.profile, wide: true)
    #expect(Set(block.map(\.kind)) == [.label, .record, .battery, .media, .iso, .lut])  // the FX3 block, minus the rest
    let unknown = CameraController(slot: CameraSlot(label: "D", color: .green, host: "test"),
                                   backend: FlakyBackend(failures: 0))
    #expect(unknown.offers(.ndPreset))  // never reported: show everything
}

@Test func savedCameraKeepsLastSeenAndDropsUnknownKinds() throws {
    var camera = SavedCamera(slot: CameraSlot(label: "C", color: .yellow, host: "x"), demoBody: .fx3)
    camera.lastSeen = CameraProfile(model: "ILME-FX3", offered: [.iso, .lut])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(camera)) as? [String: Any])
    var seen = try #require(object["lastSeen"] as? [String: Any])
    seen["offered"] = ["iso", "lut", "hologram"]
    object["lastSeen"] = seen
    let decoded = try JSONDecoder().decode(SavedCamera.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.lastSeen == CameraProfile(model: "ILME-FX3", offered: [.iso, .lut]))
}

// MARK: - iPhone arrangements

@MainActor @Test func phoneLayoutIsEditedSeparatelyFromThePage() throws {
    let store = DashboardStore.preview(page: "C")
    let page = try #require(store.currentPage?.id)
    let camera = store.cameras[2]
    store.materializePhoneLayout(page, camera: camera.id)
    let phone = try #require(store.currentPage?.phoneLayouts?[camera.id])
    #expect(phone.columns == 2)
    #expect(phone.widgets.allSatisfy { $0.cameraID == camera.id && phone.fits($0) })
    #expect(!phone.widgets.contains { $0.kind == .ndPreset })   // the FX3 has no ND
    #expect(store.currentPage?.layout == nil)                    // the page itself stays automatic

    // Move the REC tile to the top-left: the first tile there has to make room first, so swap via free rows.
    var rec = try #require(phone.widgets.first { $0.kind == .record })
    rec.y = phone.rows + 2
    #expect(store.placeWidget(page, rec, in: .phone(camera.id)))
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.first { $0.kind == .record }?.y == rec.y)
    var clash = rec
    clash.y = 0
    #expect(!store.placeWidget(page, clash, in: .phone(camera.id)))  // overlaps the first row

    store.addWidget(page, kind: .latency, cameraID: UUID(), in: .phone(camera.id))
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.last?.cameraID == camera.id)

    store.resetLayout(page, in: .phone(camera.id))
    #expect(store.currentPage?.phoneLayouts == nil)
}

@MainActor @Test func installerSeedTurnsTheDemoFX3IntoTheRealOne() throws {
    let credentials = InMemoryCredentialStore()
    let (cameras, pages) = DashboardStore.demoLineup()
    let store = DashboardStore(cameras: cameras, pages: pages, startCameras: false, credentials: credentials)
    let c = try #require(store.cameras.first { $0.slot.label == "C" })
    let seed = #"{"cameras": [{"label": "C", "host": "192.0.2.203", "username": "TW", "password": "secret", "fingerprint": "SHA256:abc"}]}"#
    #expect(store.importSeed(Data(seed.utf8)) == 1)
    let real = try #require(store.cameras.first { $0.slot.label == "C" })
    #expect(real.id == c.id)                               // same camera: its pages keep working
    #expect(real.slot.host == "192.0.2.203")
    #expect(credentials.password(for: c.id) == "secret")
    #expect(store.cameras.count == 4)
    #expect(store.importSeed(Data("not json".utf8)) == 0)
}


// Pages matching a known-old template go back to automatic; user-modified pages keep their layout.
@MainActor @Test func untouchedV2LayoutsGoBackToAutomatic() throws {
    struct V2Snapshot: Encodable {
        var version = 2
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let fx3 = MockCameraBackend.sampleState(body: .fx3)
    let profile = CameraProfile(model: fx3.model, offered: Set(WidgetKind.allCases.filter { fx3.offers($0) }))
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let c = try #require(cameras.first { $0.slot.label == "C" }?.slot.id)
    let pageC = try #require(pages.firstIndex { $0.cameraIDs == [c] && !$0.showsAllCameras })
    pages[pageC].layout = LayoutTemplates.materialize(cameraIDs: [c], profile: { _ in profile }, templates: LayoutTemplates.v2)
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    var changed = LayoutTemplates.materialize(cameraIDs: pages[pair].cameraIDs, profile: { _ in profile },
                                              templates: LayoutTemplates.v2)
    changed.widgets.removeLast()                                                  // someone deleted a tile
    pages[pair].layout = changed
    defaults.set(try JSONEncoder().encode(V2Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[pageC].layout == nil)
    #expect(store.pages[pair].layout == changed)
}

/// Saved before Live View split in two: a Live View tile was the button at the sizes in use, so it stays a button.
@MainActor @Test func savedLiveViewTilesBecomeButtons() throws {
    struct V6Snapshot: Codable {
        var version: Int? = 6
        var cameras: [SavedCamera]
        var pages: [CameraPage]
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let camera = cameras[0].slot.id
    let tile = PageWidget(kind: .liveView, cameraID: camera, x: 0, y: 0, w: 2, h: 2)
    pages[0].layout = PageLayout(columns: 4, widgets: [tile])
    var moved = tile
    moved.y = 2  // not the page's reflow, so the iPhone arrangement is kept as someone's own
    pages[0].phoneLayouts = [camera: PageLayout(columns: 2, widgets: [moved])]
    cameras[0].lastSeen = nil
    defaults.set(try JSONEncoder().encode(V6Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[0].layout?.widgets.map(\.kind) == [.liveViewButton])
    #expect(store.pages[0].phoneLayouts?[camera]?.widgets.map(\.kind) == [.liveViewButton])
}

@MainActor @Test func doneWithoutChangesKeepsThePageAutomatic() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    #expect(store.currentPage?.layout != nil)
    store.finishEditing(page)
    #expect(store.currentPage?.layout == nil)

    store.materializeLayout(page)
    let tile = try #require(store.currentPage?.layout?.widgets.first)
    store.removeWidget(page, tile.id)
    store.finishEditing(page)
    #expect(store.currentPage?.layout != nil)                                     // a real change stays
}

@MainActor @Test func newInstallStartsEmptyWithOneOptionalDemo() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.cameras.isEmpty)
    #expect(store.pages.count == 1 && store.pages[0].showsAllCameras)
    let demo = store.addDemoCamera()
    #expect(demo.isDemo)
    #expect(store.savedCamera(demo.id)?.demoBody == .fx3)
    #expect(store.visibleCameras.map(\.id) == [demo.id])
}

@MainActor @Test func aDeletedAutoPageStaysDeleted() throws {
    let saved = SavedCamera(slot: CameraSlot(label: "C", color: .yellow, host: "192.0.2.203"), connection: .demo(.fx3))
    let other = SavedCamera(slot: CameraSlot(label: "D", color: .green, host: "192.0.2.204"), connection: .demo(.fx6))
    var state = MockCameraBackend.sampleState(body: .fx3)
    state.model = "ILME-FX3"
    let store = DashboardStore(cameras: [saved, other],
                               pages: [CameraPage(id: UUID(), name: "All", cameraIDs: [], showsAllCameras: true)],
                               startCameras: false, initialStates: [saved.slot.id: state])
    let camera = try #require(store.cameras.first)
    store.checkFX3AutoPage(for: camera)
    let solo = try #require(store.pages.first { $0.cameraIDs == [camera.id] && !$0.showsAllCameras })
    #expect(solo.name == "C FX3")
    store.removePage(solo.id)
    store.checkFX3AutoPage(for: camera)
    #expect(!store.pages.contains { $0.cameraIDs == [camera.id] && !$0.showsAllCameras })
}

// MARK: - Portrait and landscape show the same tiles

@MainActor @Test func aTileAddedOnTheIPhoneAlsoAppearsInLandscape() throws {
    let store = DashboardStore.preview(page: "C")
    let page = try #require(store.currentPage?.id)
    let camera = store.cameras[2]
    store.materializePhoneLayout(page, camera: camera.id)
    #expect(store.currentPage?.layout == nil)  // the page is automatic until something changes it

    store.addWidget(page, kind: .liveView, cameraID: camera.id, in: .phone(camera.id))
    let added = try #require(store.currentPage?.phoneLayouts?[camera.id]?.widgets.last)
    #expect(added.kind == .liveView)
    // The page (landscape, iPad) has it too, under the same id, owned by the same camera.
    let onPage = try #require(store.currentPage?.layout?.widgets.first { $0.id == added.id })
    #expect(onPage.kind == .liveView && onPage.cameraID == camera.id)
    #expect(store.currentPage?.layout.map { $0.fits(onPage) || $0.widgets.allSatisfy($0.fits) } == true)

    store.removeWidget(page, added.id, in: .phone(camera.id))
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.contains { $0.id == added.id } == false)
    #expect(store.currentPage?.layout?.widgets.contains { $0.id == added.id } == false)
}

@MainActor @Test func aTileAddedOnThePageReachesThatCamerasIPhoneArrangement() throws {
    let store = DashboardStore.preview(page: "C")
    let page = try #require(store.currentPage?.id)
    let camera = store.cameras[2]
    store.materializeLayout(page)
    store.materializePhoneLayout(page, camera: camera.id)

    store.addWidget(page, kind: .liveView, cameraID: camera.id)
    let added = try #require(store.currentPage?.layout?.widgets.last)
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.contains { $0.id == added.id } == true)

    store.removeWidget(page, added.id)
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.contains { $0.id == added.id } == false)
}

@MainActor @Test func removingAnOlderTileOnTheIPhoneRemovesItsTwinFromThePage() throws {
    // Arrangements made before they were linked hold the same tile under different ids.
    let store = DashboardStore.preview(page: "C")
    let page = try #require(store.currentPage?.id)
    let camera = store.cameras[2]
    store.materializeLayout(page)
    store.materializePhoneLayout(page, camera: camera.id)
    let phoneISO = try #require(store.currentPage?.phoneLayouts?[camera.id]?.widgets.first { $0.kind == .iso })
    let pageISOs = store.currentPage?.layout?.widgets.filter { $0.kind == .iso && $0.cameraID == camera.id }.count ?? 0
    #expect(pageISOs >= 1)

    store.removeWidget(page, phoneISO.id, in: .phone(camera.id))
    let left = store.currentPage?.layout?.widgets.filter { $0.kind == .iso && $0.cameraID == camera.id }.count ?? 0
    #expect(left == pageISOs - 1)
}

// MARK: - Default layout: new tiles

// Inline-size liveView must never appear in a default template (it streams video).
@Test func noDefaultTemplateContainsLiveView() {
    for cells in [LayoutTemplates.narrowCells, LayoutTemplates.wideCells, LayoutTemplates.fx3Cells] {
        let kinds = Set(cells.map(\.0))
        #expect(!kinds.contains(.liveView), "liveView must not appear in any default template")
    }
}

@Test func noDefaultTemplateContainsOptInOnlyTiles() {
    let optIn: Set<WidgetKind> = [.haLow, .liveView]
    for cells in [LayoutTemplates.narrowCells, LayoutTemplates.wideCells, LayoutTemplates.fx3Cells] {
        let kinds = Set(cells.map(\.0))
        #expect(kinds.isDisjoint(with: optIn), "opt-in-only tiles must not appear in any default template")
    }
    // The Blackmagic block has HaLow under latency, shown only once this device has found a node
    // (`CameraController.templateProfile`); live view stays opt-in everywhere.
    #expect(!LayoutTemplates.blackmagicCells.contains { $0.0 == .liveView || $0.0 == .liveViewButton })
}

@Test func defaultsIncludePlaybackBelowREC() throws {
    for cells in [LayoutTemplates.narrowCells, LayoutTemplates.wideCells, LayoutTemplates.fx3Cells] {
        #expect(cells.contains { $0.0 == .playback })
    }
    let rec = try #require(LayoutTemplates.narrowCells.first { $0.0 == .record })
    let playback = try #require(LayoutTemplates.narrowCells.first { $0.0 == .playback })
    #expect(playback.2 + playback.4 == rec.2, "Playback directly over REC")
    #expect(LayoutTemplates.narrowCells.allSatisfy { $0.2 <= rec.2 }, "REC is the last row")
}

@Test func falseColorOnlyWhereItsOnTheOutputsAndTheFX3PageHasPlayback() throws {
    #expect(!LayoutTemplates.fx3Cells.contains { $0.0 == .falseColor })
    // A Sony body's automatic page: its LUT tile, no View Assist beside it (the same switch), no False Color tile.
    let fx6 = CameraProfile(model: "ILME-FX6",
                            offered: Set(WidgetKind.allCases.filter { MockCameraBackend.sampleState(body: .fx6).offers($0) }))
    for wide in [true, false] {
        let kinds = Set(LayoutTemplates.block(camera: UUID(), profile: fx6, wide: wide).map(\.kind))
        #expect(kinds.contains(.lut) && !kinds.contains(.viewAssist) && !kinds.contains(.falseColor))
    }
    // Nor an FX5's, whose LUT outputs are monitoring outputs as an FX6's are.
    let fx5 = CameraProfile(model: "ILME-FX5", offered: fx6.offered.union([.monitoring, .viewAssist]))
    for wide in [true, false] {
        #expect(!LayoutTemplates.block(camera: UUID(), profile: fx5, wide: wide).contains { $0.kind == .viewAssist })
    }
    // Nor one whose View Assist is Gamma Display Assist, with no LUT tile.
    let noLUT = CameraProfile(model: "ILME-FX6", offered: fx6.offered.subtracting([.lut]))
    for wide in [true, false] {
        #expect(!LayoutTemplates.block(camera: UUID(), profile: noLUT, wide: wide).contains { $0.kind == .viewAssist })
    }
    // A Blackmagic camera's: LUT and False Color on every output, its monitoring window and dynamic range.
    let pyxis = CameraProfile(model: "PYXIS 12K", offered: [.label, .status, .latency, .record, .timecode, .iso,
                                                            .viewAssist, .falseColor, .monitoring, .dynamicRange,
                                                            .resolution, .playback])
    let wideKinds = Set(LayoutTemplates.block(camera: UUID(), profile: pyxis, wide: true).map(\.kind))
    #expect(wideKinds.isSuperset(of: [.viewAssist, .falseColor, .monitoring, .dynamicRange]))
    let narrowKinds = Set(LayoutTemplates.block(camera: UUID(), profile: pyxis, wide: false).map(\.kind))
    #expect(narrowKinds.isSuperset(of: [.viewAssist, .falseColor]))
    let fx3Profile = CameraProfile(
        model: "ILME-FX3",
        offered: Set(WidgetKind.allCases.filter { MockCameraBackend.sampleState(body: .fx3).offers($0) })
    )
    let block = LayoutTemplates.block(camera: UUID(), profile: fx3Profile, wide: true)
    let lut = try #require(block.first { $0.kind == .lut })
    #expect(lut.w == 3)
    #expect(block.contains { $0.kind == .playback })
}

/// The ND tile's own Step − + are off unless switched, so every automatic page with an ND tile has ND − and
/// ND + beside it, in one row with it.
@Test func everyBlockWithNDHasItsStepTilesBesideIt() throws {
    let blocks: [(String, LayoutTemplates.Cells)] = [("narrow", LayoutTemplates.narrowCells), ("wide", LayoutTemplates.wideCells),
                                                     ("blackmagic", LayoutTemplates.blackmagicCells),
                                                     ("venice", LayoutTemplates.veniceCells), ("arri", LayoutTemplates.arriCells)]
    for (name, cells) in blocks {
        let nd = try #require(cells.first { $0.0 == .ndPreset }, "\(name)")
        let minus = try #require(cells.first { $0.0 == .ndMinus }, "\(name) has no ND −")
        let plus = try #require(cells.first { $0.0 == .ndPlus }, "\(name) has no ND +")
        #expect(minus.1 + 1 == plus.1 && minus.2 == plus.2, "\(name): ND − then ND +, side by side")
        // Beside ND in its row, or (the 2-wide column) right under it.
        #expect(minus.2 == nd.2 && minus.1 == nd.1 + nd.3 || minus.2 == nd.2 + nd.4, "\(name): ND − isn't next to ND")
    }
    #expect(!LayoutTemplates.fx3Cells.contains { $0.0 == .ndPreset || $0.0 == .ndMinus })  // the FX3 has no ND
}

/// A page someone opened in edit mode and left as it was, on the v4 block layout: back to automatic, so it gets ND −
/// and ND +. A page they changed keeps its layout, and so does an iPhone's own arrangement (only the 4-wide blocks changed).
@MainActor @Test func untouchedV4LayoutsGoBackToAutomatic() throws {
    struct V8Snapshot: Encodable {
        var version = 8
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let venice = MockCameraBackend.veniceSampleState()
    let profile = CameraProfile(model: venice.model, offered: Set(WidgetKind.allCases.filter { venice.offers($0) }), make: .sony)
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let c = try #require(cameras.first { $0.slot.label == "C" }?.slot.id)
    let pageC = try #require(pages.firstIndex { $0.cameraIDs == [c] && !$0.showsAllCameras })
    pages[pageC].layout = LayoutTemplates.materialize(cameraIDs: [c], profile: { _ in profile }, templates: LayoutTemplates.v4)
    let phone = PageLayout(columns: LayoutTemplates.narrowColumns,
                           widgets: LayoutTemplates.block(camera: c, profile: profile, wide: false, templates: LayoutTemplates.v4))
    pages[pageC].phoneLayouts = [c: phone]
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    var changed = LayoutTemplates.materialize(cameraIDs: pages[pair].cameraIDs, profile: { _ in profile },
                                              templates: LayoutTemplates.v4)
    changed.widgets.removeLast()
    pages[pair].layout = changed
    defaults.set(try JSONEncoder().encode(V8Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[pageC].layout == nil, "an untouched build-53 layout goes back to automatic")
    // v9 kept the phone (only 4-wide changed); v11 also resets phones because the narrow column changed too
    #expect(store.pages[pageC].phoneLayouts?[c] == nil, "an untouched phone that matches v6 goes back to automatic")
    #expect(store.pages[pair].layout == changed, "a real customisation must be kept")
    let automatic = LayoutTemplates.block(camera: c, profile: profile, wide: true)
    #expect(automatic.contains { $0.kind == .ndMinus } && automatic.contains { $0.kind == .ndPlus })
}

/// A Blackmagic page someone opened in edit mode and left as it was, on the v5 block: back to automatic, so it gets
/// De-squeeze under Codec. A page they changed keeps its layout.
@MainActor @Test func untouchedV5LayoutsGoBackToAutomatic() throws {
    struct V9Snapshot: Encodable {
        var version = 9
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let pyxis = MockCameraBackend.pyxisSampleState()
    let profile = CameraProfile(model: pyxis.model, offered: Set(WidgetKind.allCases.filter { pyxis.offers($0) }),
                                make: .blackmagic)
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let c = try #require(cameras.first { $0.slot.label == "C" }?.slot.id)
    let pageC = try #require(pages.firstIndex { $0.cameraIDs == [c] && !$0.showsAllCameras })
    pages[pageC].layout = LayoutTemplates.materialize(cameraIDs: [c], profile: { _ in profile }, templates: LayoutTemplates.v5)
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    var changed = LayoutTemplates.materialize(cameraIDs: pages[pair].cameraIDs, profile: { _ in profile },
                                              templates: LayoutTemplates.v5)
    changed.widgets.removeLast()
    pages[pair].layout = changed
    defaults.set(try JSONEncoder().encode(V9Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[pageC].layout == nil, "an untouched build-60 layout goes back to automatic")
    #expect(store.pages[pair].layout == changed, "a real customisation must be kept")
    let automatic = LayoutTemplates.block(camera: c, profile: profile, wide: true)
    let desqueeze = try #require(automatic.first { $0.kind == .desqueeze })
    let codec = try #require(automatic.first { $0.kind == .codec })
    #expect(desqueeze.x == codec.x && desqueeze.y == codec.maxY && desqueeze.h == 1 && codec.h == 1)
    #expect(automatic.first { $0.kind == .dynamicRange }?.h == 2)
    // Without a de-squeeze (another body, or Camera software whose presets Tiles hasn't taken apart), Codec takes the
    // whole height again.
    var withoutDesqueeze = profile
    withoutDesqueeze.offered.remove(.desqueeze)
    let closed = LayoutTemplates.block(camera: c, profile: withoutDesqueeze, wide: true)
    #expect(!closed.contains { $0.kind == .desqueeze } && closed.first { $0.kind == .codec }?.h == 2)
}

/// An untouched v6 layout goes back to automatic, gaining Battery and Media as separate tiles instead of the
/// combined Battery / Media tile. An arranged layout keeps its combined tile. Phone layouts (narrow column) are
/// also reset since the narrow column changed.
@MainActor @Test func untouchedV6LayoutsGoBackToAutomatic() throws {
    struct V10Snapshot: Encodable {
        var version = 10
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let fx3State = MockCameraBackend.sampleState(body: .fx3)
    let profile = CameraProfile(model: fx3State.model, offered: Set(WidgetKind.allCases.filter { fx3State.offers($0) }))
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let c = try #require(cameras.first { $0.slot.label == "C" }?.slot.id)
    let pageC = try #require(pages.firstIndex { $0.cameraIDs == [c] && !$0.showsAllCameras })

    // An untouched v6 layout (matches what v6 templates generate) — will be reset.
    pages[pageC].layout = LayoutTemplates.materialize(cameraIDs: [c], profile: { _ in profile }, templates: LayoutTemplates.v6)
    let v6Phone = PageLayout(columns: LayoutTemplates.narrowColumns,
                             widgets: LayoutTemplates.block(camera: c, profile: profile, wide: false, templates: LayoutTemplates.v6))
    pages[pageC].phoneLayouts = [c: v6Phone]

    // An arranged layout (modified from v6): keeps its `.status` tile untouched.
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    var changed = LayoutTemplates.materialize(cameraIDs: pages[pair].cameraIDs, profile: { _ in profile },
                                              templates: LayoutTemplates.v6)
    changed.widgets.removeLast()
    pages[pair].layout = changed

    defaults.set(try JSONEncoder().encode(V10Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)
    let store = DashboardStore.load(from: defaults, startCameras: false)

    #expect(store.pages[pageC].layout == nil, "an untouched v6 layout goes back to automatic")
    #expect(store.pages[pageC].phoneLayouts?[c] == nil, "an untouched v6 phone goes back to automatic")
    #expect(store.pages[pair].layout == changed, "an arranged layout keeps its tiles")
    // The current block has battery and media, not the combined status tile.
    let automatic = LayoutTemplates.block(camera: c, profile: profile, wide: true)
    #expect(automatic.contains { $0.kind == .battery } && automatic.contains { $0.kind == .media })
    #expect(!automatic.contains { $0.kind == .status })
}

/// The demo list has a PYXIS 12K: the Blackmagic sample, with its own letter, on the Blackmagic block.
@MainActor @Test func aDemoPYXISIsABlackmagicCamera() {
    #expect(MockBody(rawValue: "PYXIS 12K") == .pyxis12K && MockBody.pyxis12K.isBlackmagic)
    let state = MockCameraBackend.sampleState(body: .pyxis12K, label: "B")
    #expect(state.make == .blackmagic && state.model == "PYXIS 12K" && state.desqueeze != nil)
    #expect(state.fileNaming?.cameraID?.value == "B")
    let saved = SavedCamera(slot: CameraSlot(label: "B", color: .blue, host: "demo"), demoBody: .pyxis12K)
    #expect(DashboardStore.previewState(saved, lastSeen: nil).make == .blackmagic)
}

/// The Web GUI tile is gone (its web page and Tiles connected at once can trip the camera up). Some pages had one
/// from earlier layouts or from Add Tile.
/// Loading takes every one off, the row closes up and Playback takes it back, and no camera offers the tile any more.
@MainActor @Test func everyWebGUITileComesOff() throws {
    struct V8Snapshot: Encodable {
        var version = 8
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let venice = MockCameraBackend.veniceSampleState()
    let veniceProfile = CameraProfile(model: venice.model, offered: Set(WidgetKind.allCases.filter { venice.offers($0) }),
                                      make: .sony)
    var a = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "10.0.0.2"), demoBody: .venice2)
    a.lastSeen = veniceProfile
    // A VENICE page, arranged: Playback beside the template's Web GUI at the bottom, one more from Add Tile.
    var custom = LayoutTemplates.materialize(cameraIDs: [a.slot.id], profile: { _ in veniceProfile })
    let bottom = try #require(custom.widgets.firstIndex { $0.kind == .playback })
    custom.widgets[bottom].w = 3
    custom.widgets.append(PageWidget(id: LayoutTemplates.templateID(camera: a.slot.id, kind: .webGUI, occurrence: 0),
                                     kind: .webGUI, cameraID: a.slot.id, x: 3, y: custom.widgets[bottom].y, w: 1, h: 2))
    let base = custom.widgets.count - 1
    custom.widgets.append(PageWidget(kind: .webGUI, cameraID: a.slot.id, x: 0, y: custom.rows, w: 1, h: 2))
    var phone = PageLayout(columns: LayoutTemplates.narrowColumns,
                           widgets: LayoutTemplates.block(camera: a.slot.id, profile: veniceProfile, wide: false))
    phone.widgets.append(PageWidget(kind: .webGUI, cameraID: a.slot.id, x: 0, y: phone.rows, w: 2, h: 2))
    var page = CameraPage(name: "A VENICE", cameraIDs: [a.slot.id], layout: custom)
    page.phoneLayouts = [a.slot.id: phone]
    defaults.set(try JSONEncoder().encode(V8Snapshot(cameras: [a], pages: [page])), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    let fixed = try #require(store.pages[0].layout)
    #expect(!fixed.widgets.contains { $0.kind == .webGUI }, "a Web GUI tile is still on the page")
    #expect(fixed.widgets.first { $0.kind == .playback }.map { [$0.x, $0.w] } == [0, 4], "Playback takes the row back")
    #expect(fixed.widgets.count == base)
    #expect(fixed.widgets.allSatisfy { fixed.fits($0) })
    #expect(store.pages[0].phoneLayouts?[a.slot.id]?.widgets.contains { $0.kind == .webGUI } == false)
    #expect(!venice.offers(.webGUI) && !MockCameraBackend.arriSampleState().offers(.webGUI))
    #expect(!LayoutTemplates.arriCells.contains { $0.0 == .webGUI })
}

@MainActor @Test func untouchedV3LayoutsGoBackToAutomatic() throws {
    struct V5Snapshot: Encodable {
        var version = 5
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let fx3 = MockCameraBackend.sampleState(body: .fx3)
    let profile = CameraProfile(model: fx3.model, offered: Set(WidgetKind.allCases.filter { fx3.offers($0) }))
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let c = try #require(cameras.first { $0.slot.label == "C" }?.slot.id)
    let pageC = try #require(pages.firstIndex { $0.cameraIDs == [c] && !$0.showsAllCameras })
    // Store a layout that exactly matches the v3 template (untouched).
    pages[pageC].layout = LayoutTemplates.materialize(cameraIDs: [c], profile: { _ in profile }, templates: LayoutTemplates.v3)
    // A page someone actually changed keeps its layout.
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    var changed = LayoutTemplates.materialize(cameraIDs: pages[pair].cameraIDs, profile: { _ in profile },
                                              templates: LayoutTemplates.v3)
    changed.widgets.removeLast()
    pages[pair].layout = changed
    defaults.set(try JSONEncoder().encode(V5Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[pageC].layout == nil, "untouched v3 layout must be reset to automatic")
    #expect(store.pages[pair].layout == changed, "a real customisation must be kept")
}

// MARK: - False color

@MainActor @Test func falseColorRemembersTheLUTItReplacedOnTheController() async throws {
    // The demo FX3 starts on "1 ARRI Neutral G10 Slog3" and has "TW False Color".
    let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(5), connectDelay: .zero, heartbeat: nil)
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "test"), backend: backend)
    camera.start()
    try await waitUntilConnected(camera)
    camera.send(.setLUT("s709"))
    for _ in 0..<200 where camera.state.lut?.value != "s709" { try await Task.sleep(for: .milliseconds(10)) }
    camera.send(.setLUT("TW False Color"))
    for _ in 0..<200 where camera.state.lut?.value != "TW False Color" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(camera.state.lut?.value == "TW False Color")
    #expect(camera.lutBeforeFalseColor == "s709")
    #expect(isFalseColorLUT("GK_SLOG3_Log_FC") && isFalseColorLUT("GK SLog3 False Color") && !isFalseColorLUT("FCPX Rec709"))
}

// MARK: - Bundled false color LUT

private actor LUTSlotBackend: CameraBackend, LUTImportCapable {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation
    private var slots: [LUTSlot]
    private(set) var imports: [(name: String, slot: Int, bytes: Int)] = []
    private(set) var slotReads = 0

    private let model: String

    init(names: [Int: String], model: String = "ILME-FX3") {
        let stream = AsyncStream.makeStream(of: CameraState.self)
        updates = stream.stream
        continuation = stream.continuation
        slots = (1...16).map { LUTSlot(index: $0, name: names[$0]) }
        self.model = model
    }

    private func report(_ connection: ConnectionState = .connected) {
        var state = CameraState()
        state.connection = connection
        state.model = model
        let names = ["S-Log3", "s709"] + slots.compactMap { $0.name }
        state.lut = Choice("S-Log3", options: names)
        continuation.yield(state)
    }

    func connect() async { report() }
    func disconnect() async { report(.disconnected) }
    func send(_ command: CameraCommand) async { report() }   // any state update
    func lutSlots() async throws -> [LUTSlot] { slotReads += 1; return slots }
    func importLUT(data: Data, name: String, slot: Int) async throws {
        imports.append((name, slot, data.count))
        slots[slot - 1].name = name
        report()
    }
}

@MainActor private func storeWith(_ backend: LUTSlotBackend, adds: Bool = true) -> (DashboardStore, CameraController) {
    let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "test"), demoBody: .fx3)
    let store = DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                               startCameras: false, makeBackend: { _, _ in backend })
    store.addsFalseColorLUT = adds
    store.falseColorLUTData = { Data("LUT_3D_SIZE 33".utf8) }
    let controller = store.cameras[0]
    controller.start()
    return (store, controller)
}

@MainActor @Test func falseColorLUTGoesIntoTheFirstEmptySlotOfACameraWithout() async throws {
    let backend = LUTSlotBackend(names: [1: "Show LUT", 2: "s709 Clean", 4: "Day Ext"])
    let (store, camera) = storeWith(backend)   // held: the camera's hooks reach the store weakly
    for _ in 0..<300 where await backend.imports.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let imports = await backend.imports
    #expect(imports.count == 1)
    #expect(imports.first?.name == BundledLUT.falseColorName && imports.first?.slot == 3)
    for _ in 0..<200 where camera.state.lut?.options.contains(BundledLUT.falseColorName) != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    // The camera now reports it: nothing more is loaded, however many updates follow.
    camera.send(.setISO(800)); camera.send(.setISO(1600))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await backend.imports.count == 1)
    withExtendedLifetime(store) {}
}

@MainActor @Test func noFalseColorLUTIsLoadedWhenOneIsThereNoSlotIsFreeOrItIsOff() async throws {
    let hasOne = LUTSlotBackend(names: [4: "GK SLog3 False Color"])
    let a = storeWith(hasOne)
    var full: [Int: String] = [:]
    for i in 1...16 { full[i] = "LUT \(i)" }
    let noRoom = LUTSlotBackend(names: full)
    let b = storeWith(noRoom)
    let off = LUTSlotBackend(names: [1: "Show LUT"])
    let c = storeWith(off, adds: false)
    // The full one reads its slots once (under a loaded test run, not always within a fixed wait); then a little longer
    // for anything that mustn't follow.
    for _ in 0..<300 where await noRoom.slotReads == 0 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(await hasOne.imports.isEmpty)
    #expect(await noRoom.imports.isEmpty)
    #expect(await noRoom.slotReads == 1)   // read the slots, found none free
    #expect(await off.imports.isEmpty)
    #expect(await off.slotReads == 0)
    withExtendedLifetime((a, b, c)) {}
}

@MainActor @Test func onlyFX3sGetTheFalseColorLUT() async throws {
    let fx3a = LUTSlotBackend(names: [1: "Show LUT"], model: "ILME-FX3A")
    let fx30 = LUTSlotBackend(names: [1: "Show LUT"], model: "ILME-FX30")
    let fx6 = LUTSlotBackend(names: [1: "Show LUT"], model: "ILME-FX6V")
    let burano = LUTSlotBackend(names: [1: "Show LUT"], model: "MPC-2610")
    let held = [storeWith(fx3a), storeWith(fx30), storeWith(fx6), storeWith(burano)]
    for _ in 0..<300 where await fx3a.imports.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await fx3a.imports.count == 1, "the FX3A is an FX3")
    for other in [fx30, fx6, burano] {
        #expect(await other.imports.isEmpty)
        #expect(await other.slotReads == 0, "not even its slots are read")
    }
    #expect(DashboardStore.takesFalseColorLUT(model: "ILME-FX3") && !DashboardStore.takesFalseColorLUT(model: nil))
    withExtendedLifetime(held) {}
}

@Test func theBundledFalseColorLUTShipsAndIsA33PointCube() throws {
    let data = try #require(BundledLUT.falseColor)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("LUT_3D_SIZE 33"))
    let points = text.split(separator: "\n").filter { $0.first.map { $0.isNumber } ?? false }
    #expect(points.count == 33 * 33 * 33)
    #expect(isFalseColorLUT(BundledLUT.falseColorName))
}

// MARK: - Edit and use read the same; an iPhone keeps its own column

@Test func untouchedStripsKeepTheirArrangementInUse() throws {
    let camera = UUID()
    let tiles = [
        PageWidget(kind: .iso, cameraID: camera, x: 0, y: 0, w: 2, h: 4),
        PageWidget(kind: .frameRate, cameraID: camera, x: 2, y: 0, w: 1, h: 4),  // the fourth column left empty
        PageWidget(kind: .ndPreset, cameraID: camera, x: 0, y: 4, w: 2, h: 2),   // a control the camera lacks
        PageWidget(kind: .codec, cameraID: camera, x: 2, y: 4, w: 2, h: 2),
        PageWidget(kind: .lut, cameraID: camera, x: 0, y: 8, w: 4, h: 2),        // two empty half-rows above it
    ]
    let shown = LayoutTemplates.closingGaps(in: PageLayout(columns: 4, widgets: tiles)) { $0.kind != .ndPreset }
    func tile(_ kind: WidgetKind) throws -> PageWidget { try #require(shown.widgets.first { $0.kind == kind }) }
    #expect(try tile(.iso) == tiles[0] && tile(.frameRate) == tiles[1])  // a hole the user left isn't filled
    #expect(try tile(.codec).x == 0 && tile(.codec).w == 4)              // the strip that lost ND closes up
    #expect(try tile(.lut).y == 8)                                       // and the empty rows stay
}

@Test func anIPhoneShowsItsOwnColumnForACustomisedPage() throws {
    let camera = UUID()
    let fx3 = MockCameraBackend.sampleState(body: .fx3)
    let profile = CameraProfile(model: fx3.model, offered: Set(WidgetKind.allCases.filter { fx3.offers($0) }))
    let column = PageLayout(columns: 2, widgets: LayoutTemplates.block(camera: camera, profile: profile, wide: false))
    // The page's untouched FX3 block (shutter value tile and all) changes nothing on the phone.
    var page = LayoutTemplates.materialize(cameraIDs: [camera], profile: { _ in profile })
    #expect(LayoutTemplates.phone(camera: camera, profile: profile, page: nil).sameArrangement(as: column))
    #expect(LayoutTemplates.phone(camera: camera, profile: profile, page: page).sameArrangement(as: column))

    // A tile added to the page comes after the column's own, under the same id; REC stays where it was.
    let added = PageWidget(kind: .liveView, cameraID: camera, x: 0, y: page.rows, w: 2, h: 2)
    page.widgets.append(added)
    let phone = LayoutTemplates.phone(camera: camera, profile: profile, page: page)
    let rec = try #require(column.widgets.first { $0.kind == .record })
    #expect(phone.widgets.first { $0.kind == .record } == rec)
    let shown = try #require(phone.widgets.first { $0.id == added.id })
    #expect(shown.y >= rec.maxY && shown.w == 2)

    // A tile taken off the page comes off the column and the gap closes.
    page.widgets.removeAll { $0.kind == .bitrate }
    let without = LayoutTemplates.phone(camera: camera, profile: profile, page: page)
    #expect(!without.widgets.contains { $0.kind == .bitrate })
    #expect(try #require(without.widgets.first { $0.kind == .codec }).w == 2)
    #expect(without.widgets.allSatisfy { without.fits($0) })
}

@MainActor @Test func customisingOneCameraOnTheIPhoneLeavesTheOthersAlone() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let (a, b) = (store.cameras[0], store.cameras[1])
    let before = store.phoneLayout(page, camera: b.id)
    store.materializePhoneLayout(page, camera: a.id)
    store.addWidget(page, kind: .liveView, cameraID: a.id, in: .phone(a.id))
    #expect(store.currentPage?.layout != nil)  // landscape and the iPad have the tile too
    #expect(store.phoneLayout(page, camera: b.id).sameArrangement(as: before))
    // Adding a tile is all that changed on A's column, so it goes back to following the page.
    store.finishEditing(page)
    #expect(store.currentPage?.phoneLayouts?[a.id] == nil)
    #expect(store.phoneLayout(page, camera: a.id).widgets.contains { $0.kind == .liveView })
    #expect(store.addedWidgetID == store.currentPage?.layout?.widgets.first { $0.kind == .liveView }?.id)
}

@MainActor @Test func savedReflowsOfThePageGoBackToTheIPhonesColumn() throws {
    struct V7Snapshot: Encodable {
        var version = 7
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var (cameras, pages) = DashboardStore.demoLineup()
    let fx3 = MockCameraBackend.sampleState(body: .fx3)
    let profile = CameraProfile(model: fx3.model, offered: Set(WidgetKind.allCases.filter { fx3.offers($0) }))
    for index in cameras.indices { cameras[index].lastSeen = profile }
    let pair = try #require(pages.firstIndex { $0.cameraIDs.count == 2 })
    let (a, b) = (pages[pair].cameraIDs[0], pages[pair].cameraIDs[1])
    let layout = LayoutTemplates.materialize(cameraIDs: [a, b], profile: { _ in profile })
    var changed = LayoutTemplates.compact(layout, camera: b)
    changed.widgets.removeLast()
    pages[pair].layout = layout
    pages[pair].phoneLayouts = [a: LayoutTemplates.compact(layout, camera: a), b: changed]
    defaults.set(try JSONEncoder().encode(V7Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(store.pages[pair].phoneLayouts?[a] == nil, "an untouched reflow follows the iPhone's column again")
    #expect(store.pages[pair].phoneLayouts?[b] == changed, "an arrangement someone changed is kept")
}

@MainActor @Test func aLoneFX3GetsItsPageWhenASecondCameraJoins() throws {
    var state = MockCameraBackend.sampleState(body: .fx3, label: "A")
    state.model = "ILME-FX3"
    let slot = CameraSlot(label: "A", color: .red, host: "192.168.1.20")
    let store = DashboardStore(cameras: [SavedCamera(slot: slot, demoBody: .fx3)],
                               pages: [CameraPage(name: "All", showsAllCameras: true)],
                               startCameras: false, initialStates: [slot.id: state])
    let fx3 = try #require(store.cameras.first)
    store.checkFX3AutoPage(for: fx3)
    #expect(store.pages.map(\.name) == ["All"])  // All already shows just this FX3
    store.addCamera(label: "B", color: .blue, host: "demo", demoBody: .fx6)
    store.checkFX3AutoPage(for: fx3)
    #expect(store.pages.map(\.name) == ["All", "A FX3"])
}

@Test func camerasSideBySideLineUpRowByRow() throws {
    // An FX5, an FX3 and an FX30 side by side: the FX5 showing False Color, each column closed up on its own,
    // and the FX3's and FX30's REC grew to the page's bottom, nearly twice the FX5's.
    let fx5 = UUID(), fx3 = UUID(), fx30 = UUID()
    let fx3State = MockCameraBackend.sampleState(body: .fx3)
    let fx3Profile = CameraProfile(model: "ILME-FX3", offered: Set(WidgetKind.allCases.filter { fx3State.offers($0) }))
    let fx5Profile = CameraProfile(model: "ILME-FX5", offered: fx3Profile.offered.union([.falseColor]))
    #expect(!fx3Profile.offered.contains(.falseColor) && !fx3Profile.offered.contains(.ndPreset))
    let layout = LayoutTemplates.materialize(cameraIDs: [fx5, fx3, fx30], wide: false,
                                             profile: { $0 == fx5 ? fx5Profile : fx3Profile })
    let recs = layout.widgets.filter { $0.kind == .record }
    #expect(recs.count == 3 && recs.allSatisfy { $0.maxY == layout.rows })
    #expect(Set(recs.map(\.h)) == [LayoutTemplates.narrow(camera: fx3).first { $0.kind == .record }!.h], "one size")
    // Each control on one row and at one size across the page.
    for kind in [WidgetKind.iso, .shutterDial, .frameRate, .wbSliders, .codec, .playback] {
        let tiles = layout.widgets.filter { $0.kind == kind }
        #expect(tiles.count == 3 && Set(tiles.map(\.y)).count == 1 && Set(tiles.map(\.h)).count == 1, "\(kind)")
    }
    // False Color in the FX5's column alone, its row left empty in the others'; a row none of them uses (ND) closes.
    #expect(layout.widgets.filter { $0.kind == .falseColor }.map(\.cameraID) == [fx5])
    let iso = try #require(layout.widgets.first { $0.kind == .iso && $0.cameraID == fx3 })
    #expect(iso.y < LayoutTemplates.narrow(camera: fx3).first { $0.kind == .iso }!.y, "the ND rows closed up")
    #expect(layout.widgets.allSatisfy { layout.fits($0) })
    // A camera on its own still closes up every row it doesn't use.
    let alone = LayoutTemplates.materialize(cameraIDs: [fx3], wide: false, profile: { _ in fx3Profile })
    #expect(alone.rows < layout.rows)
}

@MainActor @Test func aNewInstallLeavesCamerasLUTSlotsAlone() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DashboardStore.load(from: defaults, startCameras: false).addsFalseColorLUT == false)
    #expect(DashboardStore.load(from: defaults, startCameras: false).addsFalseColorLUT == false)  // and stays off

    // A setup saved before the setting existed keeps loading the LUT.
    let older = try #require(UserDefaults(suiteName: suite + ".older"))
    defer { older.removePersistentDomain(forName: suite + ".older") }
    struct V8Snapshot: Encodable {
        var version = 8
        var cameras: [SavedCamera]
        var pages: [CameraPage]
    }
    let (cameras, pages) = DashboardStore.demoLineup()
    older.set(try JSONEncoder().encode(V8Snapshot(cameras: cameras, pages: pages)), forKey: DashboardStore.storageKey)
    #expect(DashboardStore.load(from: older, startCameras: false).addsFalseColorLUT == true)
}

/// A setup with a camera or profile this build can't read (a kind a newer build added) keeps everything else.
@MainActor @Test func aCameraFromANewerBuildDoesntLoseTheRest() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DashboardStore.load(from: defaults, startCameras: false)
    store.addCamera(label: "A", color: .red, host: "", demoBody: .fx3)
    store.addCamera(label: "B", color: .blue, host: "203.0.113.120", connection: .arri(ArriConnection(host: "203.0.113.120")))
    store.addProfile(CameraProfileRecord(name: "Mini", address: "203.0.113.121", cameraType: .arri))
    store.addProfile(CameraProfileRecord(name: "FX3", address: "203.0.113.122", cameraType: .sony))
    let saved = try #require(defaults.data(forKey: DashboardStore.storageKey))
    var json = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    var cameras = try #require(json["cameras"] as? [[String: Any]])
    #expect(cameras.count == 2)
    cameras[1]["connection"] = ["hologram": ["_0": ["host": "203.0.113.120"]]]
    json["cameras"] = cameras
    var profiles = try #require(json["profiles"] as? [[String: Any]])
    profiles[0]["cameraType"] = "hologram"
    json["profiles"] = profiles
    defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: DashboardStore.storageKey)

    let reloaded = DashboardStore.load(from: defaults, startCameras: false)
    #expect(reloaded.cameras.map(\.slot.label) == ["A"], "the camera it can't read is left out, not everything")
    #expect(reloaded.profiles.map(\.name) == ["FX3"])
    #expect(!reloaded.pages.isEmpty)
}

@Test func usbAddressesAreUniquePerCameraAndReadAsUSB() {
    #expect(USBCameraAddress.host(serial: "0123456789AB") == "usb:0123456789AB")
    #expect(USBCameraAddress.serial(in: "usb:0123456789AB") == "0123456789AB")
    #expect(USBCameraAddress.serial(in: "usb:") == nil)
    #expect(USBCameraAddress.serial(in: "192.0.2.23") == nil)
    #expect(USBCameraAddress.display("usb:0123456789AB") == "USB")
    #expect(USBCameraAddress.display("192.0.2.23") == "192.0.2.23")
}

@Test func aCabledCameraStreamsLiveViewAtItsOwnRate() {
    let cabled = LiveViewConfig.cabled
    #expect(cabled.quality == .high && cabled.autoStopSeconds == nil)
    #expect(cabled.frameInterval >= 0.033, "the spec's limit: no more than two calls per 33 ms")
    let network = LiveViewConfig()
    #expect(network.quality == .low && network.frameInterval == 1 && network.autoStopSeconds == 20)
}

@Test func liveViewChoicesOverrideTheLinksOnlyWhereMade() {
    let cabled = LiveViewConfig.cabled
    #expect(LiveViewSettings().applied(to: cabled).quality == .high)
    let chosen = LiveViewSettings(quality: .low, framesPerSecond: 10).applied(to: cabled)
    #expect(chosen.quality == .low && chosen.frameInterval == 0.1 && chosen.autoStopSeconds == nil)
    #expect(LiveViewSettings.frameRates.max() == 30, "the most the camera serves")
}

@MainActor @Test func aCamerasLiveViewChoicesAreSavedWithIt() throws {
    let defaults = try #require(UserDefaults(suiteName: "liveview-\(UUID())"))
    let saved = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "usb:X"), demoBody: .fx3)
    let store = DashboardStore(cameras: [saved], pages: [CameraPage(name: "All", showsAllCameras: true)],
                               defaults: defaults, startCameras: false)
    store.cameras[0].liveViewSettings = LiveViewSettings(quality: .low, framesPerSecond: 5)
    let reloaded = DashboardStore.load(from: defaults, startCameras: false)
    #expect(reloaded.cameras.first?.liveViewSettings == LiveViewSettings(quality: .low, framesPerSecond: 5))
}

// MARK: - Live View tile shape

@Test func aLiveViewTileIsTallEnoughForA16x9Picture() {
    // An iPad mini page in landscape: 270 pt columns and 43 pt half-rows. Two columns are 548 pt across, so the
    // picture is 308 pt tall: six half-rows and their gaps.
    #expect(GridCellShape(cellWidth: 270, rowHeight: 43, gap: 8).halfRows(forPictureAcross: 2) == 6)
    #expect(GridCellShape(cellWidth: 100, rowHeight: 200, gap: 8).halfRows(forPictureAcross: 1) == 2, "two at least")
}

@MainActor @Test func addTileGivesLiveViewItsPicturesShape() throws {
    let store = DashboardStore.preview(page: "C")
    let page = try #require(store.currentPage?.id)
    let camera = store.cameras[2]
    store.materializeLayout(page)
    store.editedGrid = (page, .page, GridCellShape(cellWidth: 270, rowHeight: 43, gap: 8))
    store.addWidget(page, kind: .liveView, cameraID: camera.id)
    let added = try #require(store.currentPage?.layout?.widgets.last)
    #expect(added.kind == .liveView && added.w == 2 && added.h == 6)
    // With no grid drawn for it, the palette's size.
    store.editedGrid = nil
    store.addWidget(page, kind: .liveView, cameraID: camera.id)
    #expect(store.currentPage?.layout?.widgets.last?.h == WidgetKind.liveView.defaultSize.h)
}

// MARK: - A camera plugged back in

@MainActor @Test func aCameraPluggedBackInReconnectsWithoutWaitingForItsRetry() async throws {
    let backend = FlakyBackend(failures: 1)
    // The retry is a minute off: only reconnectNow brings it back inside the test.
    let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "usb:X"),
                                  backend: backend, initialRetryDelay: 60)
    camera.start()
    for _ in 0..<500 where camera.state.connection != .failed("link down") {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    camera.reconnectNow()
    try await waitUntilConnected(camera)
    #expect(camera.state.connection == .connected)
    #expect(await backend.connects == 2)
    camera.reconnectNow()  // a camera that's up is left alone
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await backend.connects == 2)
}

/// A Blackmagic camera's own block: with every tile it has, the tiles land in the standard positions;
/// without HaLow nodes, latency takes the whole corner; a Sony body never gets it.
@Test func blackmagicBlockIsWillsLayout() throws {
    let pyxis: Set<WidgetKind> = [.label, .battery, .media, .timecode, .latency, .haLow, .record, .iso, .shutterDial, .shutterValue,
                                  .frameRate, .resolution, .codec, .dynamicRange, .wbSliders, .wbPreset, .viewAssist,
                                  .falseColor, .frameGuides, .monitoring, .playback, .clipName]
    let block = LayoutTemplates.block(camera: UUID(), profile: CameraProfile(model: "PYXIS 12K", offered: pyxis, make: .blackmagic),
                                      wide: true)
    func at(_ kind: WidgetKind) throws -> [Int] {
        let w = try #require(block.first { $0.kind == kind }, "\(kind)")
        return [w.x, w.y, w.w, w.h]
    }
    #expect(try at(.latency) == [3, 0, 1, 1] && at(.haLow) == [3, 1, 1, 1])
    #expect(try at(.shutterValue) == [3, 2, 1, 4])
    #expect(try at(.frameRate) == [0, 6, 1, 2] && at(.dynamicRange) == [3, 6, 1, 2])
    #expect(try at(.wbSliders) == [0, 8, 3, 3] && at(.wbPreset) == [3, 8, 1, 3])
    #expect(try at(.viewAssist) == [0, 11, 1, 2] && at(.monitoring) == [3, 11, 1, 2])   // no iris: its strip closes
    #expect(try at(.playback) == [0, 13, 3, 2] && at(.clipName) == [3, 13, 1, 2])

    let noNode = LayoutTemplates.block(camera: UUID(), profile: CameraProfile(model: "PYXIS 12K", offered: pyxis.subtracting([.haLow]),
                                                                              make: .blackmagic), wide: true)
    #expect(noNode.first { $0.kind == .latency }.map { [$0.y, $0.h] } == [0, 2])

    // A lens the camera drives: iris gets the row under WB. A body with filters: ND with ND − and ND + under it
    // (the ND tile's own Step − + are off by default, so these standalone buttons are in the block instead).
    func rows(_ offered: Set<WidgetKind>) -> [[Int]] {
        LayoutTemplates.block(camera: UUID(), profile: CameraProfile(model: "URSA Cine 12K LF", offered: offered, make: .blackmagic),
                              wide: true)
            .filter { [.iris, .ndPreset, .ndMinus, .ndPlus].contains($0.kind) }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map { [$0.x, $0.y, $0.w, $0.h] }
    }
    #expect(rows(pyxis.union([.iris])) == [[0, 11, 4, 2]])
    #expect(rows(pyxis.union([.iris, .ndPreset, .ndMinus, .ndPlus])) == [[0, 11, 4, 2], [0, 13, 2, 2], [2, 13, 1, 2], [3, 13, 1, 2]])
    #expect(rows(pyxis.union([.ndPreset, .ndMinus, .ndPlus])) == [[0, 11, 2, 2], [2, 11, 1, 2], [3, 11, 1, 2]])

    let fx6 = CameraProfile(model: "ILME-FX6", offered: pyxis, make: .sony)
    #expect(!LayoutTemplates.block(camera: UUID(), profile: fx6, wide: true).contains { $0.kind == .haLow })
}

/// The HaLow tile on a Blackmagic camera's automatic page waits for this device to find a node, then stays on later
/// runs too, so the page doesn't change shape at launch while the monitor looks again. Arranged pages always keep it.
@MainActor @Test func automaticHaLowTileFollowsNodesSeen() throws {
    let suite = "test.halow.seen.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var state = MockCameraBackend.sampleState(body: .fx6, label: "A")
    state.make = .blackmagic
    state.model = "PYXIS 12K"
    let slot = CameraSlot(label: "A", color: .red, host: "198.51.100.105")
    func store() -> DashboardStore {
        DashboardStore(cameras: [SavedCamera(slot: slot, demoBody: .fx6)], pages: [CameraPage(name: "All", showsAllCameras: true)],
                       defaults: defaults, startCameras: false, initialStates: [slot.id: state])
    }
    let first = store()
    #expect(first.cameras[0].templateProfile?.offered.contains(.haLow) == false)
    #expect(first.cameras[0].profile?.offered.contains(.haLow) == true)
    first.previewHaLowNodes([HaLowNode(address: "192.0.2.2", name: "node-2", isLocal: true, state: .polling)])
    #expect(first.cameras[0].templateProfile?.offered.contains(.haLow) == true)
    #expect(store().cameras[0].templateProfile?.offered.contains(.haLow) == true)
}

/// A tile's minimum is the smallest size its content reads at, and every built-in template already shows each tile at a
/// size that reads: a minimum above a template's size would stop the user resizing a tile back to how the app laid it out.
@Test func tileMinimumsFitEveryTemplate() {
    let sets: [(String, LayoutTemplates.Cells)] = [("narrow", LayoutTemplates.narrowCells), ("wide", LayoutTemplates.wideCells),
                                                   ("fx3", LayoutTemplates.fx3Cells), ("blackmagic", LayoutTemplates.blackmagicCells),
                                                   ("venice", LayoutTemplates.veniceCells), ("arri", LayoutTemplates.arriCells)]
    for (name, cells) in sets {
        for (kind, _, _, w, h) in cells {
            let minimum = kind.minimumSize
            #expect(w >= minimum.w && h >= minimum.h, "\(name): \(kind) is \(w)×\(h), below its minimum \(minimum.w)×\(minimum.h)")
        }
    }
}

// MARK: - A monitoring switch set to one output

/// Page "A": one PYXIS 12K with an LCD and an SDI out, SDI on clean feed.
@MainActor private func pyxisStore() -> (DashboardStore, CameraController) {
    func output(_ id: String, _ name: String, _ on: Set<MonitorOverlay>) -> MonitorOutput {
        MonitorOutput(id: id, name: name, overlays: Dictionary(uniqueKeysWithValues: [MonitorOverlay.lut, .falseColor, .zebra,
            .focusAssist, .frameGuides, .cleanFeed].map { ($0, Choice(on.contains($0), options: [false, true])) }))
    }
    var state = MockCameraBackend.sampleState(body: .fx6, label: "A")
    state.make = .blackmagic
    state.model = "PYXIS 12K"
    state.monitoring = MonitoringState(outputs: [output("LCD", "LCD", [.lut, .frameGuides]), output("MainSDI", "SDI", [.lut, .cleanFeed])])
    state.look = state.monitoring?.onEverywhere(.lut)
    state.falseColor = state.monitoring?.onEverywhere(.falseColor)
    let slot = CameraSlot(label: "A", color: .red, host: "198.51.100.105")
    let store = DashboardStore(cameras: [SavedCamera(slot: slot, demoBody: .fx6)],
                               pages: [CameraPage(name: "A", cameraIDs: [slot.id])],
                               startCameras: false, initialStates: [slot.id: state])
    return (store, store.cameras[0])
}

/// A tile without an output saves exactly as before, so builds from before it read the layout the same; one with an
/// output keeps it.
@Test func aTileWithoutAnOutputSavesAsItAlwaysDid() throws {
    let widget = PageWidget(kind: .falseColor, cameraID: UUID(), x: 0, y: 0, w: 1, h: 2)
    let saved = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(widget)) as? [String: Any])
    #expect(saved["output"] == nil)
    let older = #"{"id":"\#(UUID().uuidString)","kind":"falseColor","cameraID":"\#(UUID().uuidString)","x":0,"y":0,"w":1,"h":2}"#
    #expect(try JSONDecoder().decode(PageWidget.self, from: Data(older.utf8)).output == nil)
    var sdi = widget
    sdi.output = TileOutput(id: "MainSDI", name: "SDI")
    #expect(try JSONDecoder().decode(PageWidget.self, from: JSONEncoder().encode(sdi)) == sdi)
}

@MainActor @Test func aCleanFeedTileStartsOnTheCamerasSDI() throws {
    let (store, camera) = pyxisStore()
    let page = try #require(store.currentPage?.id)
    #expect(camera.offers(.cleanFeed))
    store.materializeLayout(page)
    store.addWidget(page, kind: .cleanFeed, cameraID: camera.id)
    let added = try #require(store.currentPage?.layout?.widgets.last)
    #expect(added.kind == .cleanFeed && added.output == TileOutput(id: "MainSDI", name: "SDI"))
    store.addWidget(page, kind: .zebra, cameraID: camera.id)
    #expect(store.currentPage?.layout?.widgets.last?.output == nil)
}

/// Portrait and landscape show the same tile: set on the page, the iPhone's column has it; set on the iPhone, the page.
@MainActor @Test func aTilesOutputIsTheSameOnTheIPhone() throws {
    let (store, camera) = pyxisStore()
    let page = try #require(store.currentPage?.id)
    let sdi = TileOutput(id: "MainSDI", name: "SDI")
    store.materializeLayout(page)
    let falseColor = try #require(store.currentPage?.layout?.widgets.first { $0.kind == .falseColor })
    store.setWidgetOutput(page, falseColor.id, output: sdi)
    #expect(store.currentPage?.layout?.widgets.first { $0.id == falseColor.id }?.output == sdi)
    #expect(store.phoneLayout(page, camera: camera.id).widgets.first { $0.id == falseColor.id }?.output == sdi)

    store.materializePhoneLayout(page, camera: camera.id)
    store.setWidgetOutput(page, falseColor.id, output: nil, in: .phone(camera.id))
    #expect(store.currentPage?.phoneLayouts?[camera.id]?.widgets.first { $0.id == falseColor.id }?.output == nil)
    #expect(store.currentPage?.layout?.widgets.first { $0.id == falseColor.id }?.output == nil)

    // On an automatic page, setting it on the iPhone makes the page explicit to hold it, as any edit there does.
    let (fresh, pyxis) = pyxisStore()
    let other = try #require(fresh.currentPage?.id)
    fresh.materializePhoneLayout(other, camera: pyxis.id)
    let lut = try #require(fresh.currentPage?.phoneLayouts?[pyxis.id]?.widgets.first { $0.kind == .viewAssist })
    fresh.setWidgetOutput(other, lut.id, output: sdi, in: .phone(pyxis.id))
    #expect(fresh.currentPage?.layout?.widgets.first { $0.id == lut.id }?.output == sdi)
}

/// Setting an output is an edit: Done keeps the page as arranged. Put back on every output, it's automatic again.
@MainActor @Test func anOutputSurvivesDone() throws {
    let (store, _) = pyxisStore()
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    let guides = try #require(store.currentPage?.layout?.widgets.first { $0.kind == .frameGuides })
    store.setWidgetOutput(page, guides.id, output: TileOutput(id: "LCD", name: "LCD"))
    store.finishEditing(page)
    #expect(store.currentPage?.layout?.widgets.first { $0.id == guides.id }?.output?.id == "LCD")
    store.setWidgetOutput(page, guides.id, output: nil)
    store.finishEditing(page)
    #expect(store.currentPage?.layout == nil)
    // Only monitoring switches take an output.
    store.materializeLayout(page)
    let iso = try #require(store.currentPage?.layout?.widgets.first { $0.kind == .iso })
    store.setWidgetOutput(page, iso.id, output: TileOutput(id: "LCD", name: "LCD"))
    #expect(store.currentPage?.layout?.widgets.first { $0.id == iso.id }?.output == nil)
}

/// A tile set to an output its camera hasn't got (moved to another model) drops out in use, like any missing control.
@MainActor @Test func aTileForAnOutputTheCameraHasntGotIsLeftOutInUse() throws {
    let (_, camera) = pyxisStore()
    var tile = PageWidget(kind: .falseColor, cameraID: camera.id, x: 0, y: 0, w: 1, h: 2,
                          output: TileOutput(id: "MonitorSDI", name: "Monitor SDI"))
    #expect(!camera.offers(tile))
    tile.output = TileOutput(id: "MainSDI", name: "SDI")
    #expect(camera.offers(tile))
    tile.output = nil
    #expect(camera.offers(tile))
}

// MARK: - Editing a page with its camera offline

/// A PYXIS that isn't connected, saved with what it reported last: `offered` and `outputs` as a current build saves
/// them, or (`older`) as an older build did, without Clean Feed or outputs.
@MainActor private func offlinePyxisStore(older: Bool = false, outputs: [TileOutput]? = nil) -> (DashboardStore, CameraController) {
    let sample = MockCameraBackend.pyxisSampleState()
    var camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "198.51.100.105"),
                             connection: .blackmagic(BlackmagicConnection(host: "198.51.100.105", useHTTPS: true)))
    var offered = Set(WidgetKind.allCases.filter { sample.offers($0) })
    if older { offered.remove(.cleanFeed) }
    camera.lastSeen = CameraProfile(model: "PYXIS 12K", offered: offered, make: .blackmagic,
                                    outputs: older ? nil : outputs ?? sample.monitoring?.outputs.map(TileOutput.init))
    let store = DashboardStore(cameras: [camera], pages: [CameraPage(name: "A", cameraIDs: [camera.slot.id])],
                               startCameras: false)
    return (store, store.cameras[0])
}

/// Edit mode draws a camera that isn't connected as a demo of itself: its own letter and id, the sample values for its
/// model, the outputs it had. A connected camera, and a demo camera, are drawn as they are.
@MainActor @Test func anOfflineCameraIsADemoOfItselfInEditMode() throws {
    let (store, camera) = offlinePyxisStore()
    #expect(!camera.state.connection.isControllable)
    let preview = try #require(store.previewController(for: camera))
    #expect(preview.id == camera.id && preview.slot == camera.slot && preview.isDemo)
    #expect(preview.state.connection.isControllable && preview.state.model == "PYXIS 12K")
    #expect(preview.state.monitoring?.outputs.map(\.id) == ["LCD", "FrontUSBC", "RearUSBC", "MainSDI"])
    #expect(store.previewController(for: camera) === preview)   // the same stand-in while nothing about the camera changes
    // The camera itself is untouched: still offline, still its saved report.
    #expect(!camera.state.connection.isControllable && camera.profile == store.savedCamera(camera.id)?.lastSeen)

    let (connected, pyxis) = pyxisStore()
    #expect(connected.previewController(for: pyxis) == nil)
    let demo = DashboardStore.preview(page: "C")
    #expect(demo.cameras.allSatisfy { demo.previewController(for: $0) == nil })
}

/// The demo has the outputs the camera reported, not the sample's, where they differ.
@MainActor @Test func aCamerasDemoHasItsOwnOutputs() throws {
    let outputs = [TileOutput(id: "LCD", name: "LCD"), TileOutput(id: "MonitorSDI", name: "Monitor SDI")]
    let (store, camera) = offlinePyxisStore(outputs: outputs)
    let monitoring = try #require(store.previewController(for: camera)?.state.monitoring)
    #expect(monitoring.outputs.map(\.id) == ["LCD", "MonitorSDI"])
    #expect(monitoring.outputs.last?.name == "Monitor SDI" && monitoring.outputs.last?.overlays[.cleanFeed]?.value == false)
}

/// A PYXIS last seen by an older build without Clean Feed or outputs saved offers Clean Feed in Add Tile before it next
/// connects, and the tile starts on SDI.
@MainActor @Test func cleanFeedCanBeAddedForAnOfflineCamera() throws {
    let (store, camera) = offlinePyxisStore(older: true)
    #expect(!camera.offers(.cleanFeed))
    #expect(store.tileKinds(for: camera).contains(.cleanFeed))
    #expect(!store.tileKinds(for: camera).contains(.look) && !store.tileKinds(for: camera).contains(.format))
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    store.addWidget(page, kind: .cleanFeed, cameraID: camera.id)
    #expect(store.currentPage?.layout?.widgets.last?.output == TileOutput(id: "MainSDI", name: "SDI"))
}

/// The Lock tile is the app's, not the camera's: every camera offers it whatever it has reported, and
/// a page's Lock tile stays in use while its camera is offline, even for a camera last seen by a build from before the
/// tile, whose saved profile hasn't got it. Add Tile lists it; no default layout has it.
@MainActor @Test func theLockTileIsEveryCamerasAndInNoDefaultLayout() throws {
    #expect(CameraState().offers(.lock))
    for body in MockBody.allCases { #expect(MockCameraBackend.sampleState(body: body).offers(.lock), "\(body)") }

    let sample = MockCameraBackend.pyxisSampleState()
    var saved = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "198.51.100.105"),
                            connection: .blackmagic(BlackmagicConnection(host: "198.51.100.105", useHTTPS: true)))
    // What an older build saved: everything the camera reported, and no Lock tile.
    saved.lastSeen = CameraProfile(model: "PYXIS 12K", offered: Set(WidgetKind.allCases.filter { sample.offers($0) && $0 != .lock }),
                                   make: .blackmagic)
    let store = DashboardStore(cameras: [saved], pages: [CameraPage(name: "A", cameraIDs: [saved.slot.id])], startCameras: false)
    let camera = store.cameras[0]
    #expect(!camera.state.connection.isControllable && camera.profile?.offered.contains(.lock) == false)
    #expect(camera.offers(.lock))
    #expect(store.tileKinds(for: camera).contains(.lock))

    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    store.addWidget(page, kind: .lock, cameraID: camera.id)
    let layout = try #require(store.currentPage?.layout)
    let tile = try #require(layout.widgets.first { $0.kind == .lock })
    #expect((tile.w, tile.h) == (1, 2))
    // In use a page drops the tiles its camera hasn't got, and the iPhone shows its own column: the Lock tile is in both.
    #expect(LayoutTemplates.closingGaps(in: layout) { store.camera($0.cameraID)?.offers($0) ?? true }.widgets.contains { $0.id == tile.id })
    #expect(store.phoneLayout(page, camera: camera.id).widgets.contains { $0.kind == .lock })

    let templates: [LayoutTemplates.Cells] = [LayoutTemplates.narrowCells, LayoutTemplates.wideCells, LayoutTemplates.fx3Cells,
                                              LayoutTemplates.blackmagicCells, LayoutTemplates.veniceCells, LayoutTemplates.arriCells]
    #expect(templates.allSatisfy { cells in !cells.contains { $0.0 == .lock } })
}

/// A Sony camera's demo is the body it reported.
@MainActor @Test func anOfflineSonyCameraIsADemoOfItsOwnBody() throws {
    var camera = SavedCamera(slot: CameraSlot(label: "B", color: .blue, host: "192.0.2.6"), connection: .sony(SonyConnection()))
    camera.lastSeen = CameraProfile(model: "ILME-FX6", offered: [.iso, .ndPreset], make: .sony)
    let store = DashboardStore(cameras: [camera], pages: [CameraPage(name: "B", cameraIDs: [camera.slot.id])], startCameras: false)
    let preview = try #require(store.previewController(for: store.cameras[0]))
    // An FX6's own outputs (its LUT on SDI/HDMI and the viewfinder), not a Blackmagic demo's.
    #expect(preview.state.model == "ILME-FX6" && preview.state.nd != nil)
    #expect(preview.state.monitoring?.outputs.map(\.name) == ["SDI/HDMI", "VF"])
}

/// Test Mode: an offline camera runs as a working demo of itself on every page, its tiles changing the demo's values
/// (a Blackmagic camera's outputs included); the camera itself is never touched. Off, pages show the camera itself.
@MainActor @Test func testModeMakesAnOfflineCameraAWorkingDemo() async throws {
    let (store, camera) = offlinePyxisStore()
    #expect(store.shownController(for: camera) === camera)
    let still = try #require(store.previewController(for: camera))
    #expect(store.shownController(for: camera, editing: true) === still)

    store.testMode = true
    let demo = store.shownController(for: camera)
    #expect(demo !== camera && demo !== still && demo.isDemo && demo.id == camera.id)
    #expect(store.shownController(for: camera, editing: true) === demo)   // edit mode draws the same one
    #expect(store.shownCamera(camera.id) === demo)                        // and so do the sheets its tiles open
    demo.send(.setISO(1600))
    demo.send(.setMonitorOverlay(.zebra, true, output: "FrontUSBC"))
    demo.send(.setLook(false))
    // The look reads off before every output's LUT has followed it: waited for together (once, under load, the look
    // was off and an output's LUT not yet).
    let worked = await waitUntilMain {
        demo.state.iso?.value == 1600 && demo.state.look?.value == false
            && demo.state.monitoring?.outputs.first { $0.id == "FrontUSBC" }?.overlays[.zebra]?.value == true
            && demo.state.monitoring?.outputs.allSatisfy { $0.overlays[.lut]?.value == false } == true
    }
    #expect(worked)
    #expect(demo.state.monitoring?.outputs.allSatisfy { $0.overlays[.lut]?.value == false } == true)
    #expect(!camera.state.connection.isControllable && camera.state.iso == nil)

    store.testMode = false
    #expect(store.shownController(for: camera) === camera)
    #expect(store.previewController(for: camera) !== demo)   // back to a still demo for edit mode
}

@MainActor @Test func testModeIsRemembered() throws {
    let defaults = try #require(UserDefaults(suiteName: "tw-cc-test-\(UUID().uuidString)"))
    let store = DashboardStore.load(from: defaults, startCameras: false)
    #expect(!store.testMode)
    store.testMode = true
    #expect(DashboardStore.load(from: defaults, startCameras: false).testMode)
}

/// Every tile of one camera on a page goes to another in one step: a page laid out on a demo camera goes to the real
/// one, with its iPhone arrangement where the real one hasn't its own.
@MainActor @Test func moveTilesGivesEveryTileToTheOtherCamera() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let a = store.cameras[0].id, b = store.cameras[1].id
    store.materializeLayout(page)
    store.materializePhoneLayout(page, camera: b)
    let bTiles = try #require(store.currentPage?.layout?.widgets.filter { $0.cameraID == b }.map(\.id))
    let aCount = store.currentPage?.layout?.widgets.filter { $0.cameraID == a }.count ?? 0
    #expect(!bTiles.isEmpty)

    store.moveTiles(page, from: b, to: a)
    let layout = try #require(store.currentPage?.layout)
    #expect(!layout.widgets.contains { $0.cameraID == b })
    #expect(layout.widgets.filter { $0.cameraID == a }.count == aCount + bTiles.count)
    #expect(Set(layout.widgets.filter { bTiles.contains($0.id) }.map(\.cameraID)) == [a])
    #expect(store.currentPage?.phoneLayouts?[b] == nil)
    #expect(store.currentPage?.phoneLayouts?[a]?.widgets.allSatisfy { $0.cameraID == a } == true)
    #expect(store.currentPage?.cameraIDs.contains(b) == false)
    store.moveTiles(page, from: a, to: a)   // nothing to do
    #expect(store.currentPage?.layout == layout)
}

/// A camera's outputs are kept with what it reported, so they're there while it's offline; a profile saved before
/// they were kept reads without them.
@MainActor @Test func aCamerasOutputsAreSavedWithItsProfile() throws {
    let (_, camera) = pyxisStore()
    let profile = try #require(camera.profile)
    #expect(profile.outputs?.map(\.id) == ["LCD", "MainSDI"])
    #expect(try JSONDecoder().decode(CameraProfile.self, from: JSONEncoder().encode(profile)) == profile)
    let older = #"{"model":"PYXIS 12K","offered":["iso","monitoring"],"make":"blackmagic"}"#
    #expect(try JSONDecoder().decode(CameraProfile.self, from: Data(older.utf8)).outputs == nil)
    #expect(MockCameraBackend.sampleState(body: .fx3).monitoring == nil)   // a Sony body's profile has none
}

/// A tap on the User Frame tile steps as the camera's "User Frame Disp." button does (on set they're cycled from a hot
/// button): both, the first, the second, none, and round again; Off and On on a camera with one.
@Test func userFrameLinesStepAsTheCamerasButtonDoes() {
    var state = UserFrameLines.off
    var seen: [String] = []
    for _ in 0..<5 {
        state = UserFrameLines.next(after: state, in: UserFrameLines.options) ?? "?"
        seen.append(state)
    }
    #expect(seen == ["1 + 2", "1", "2", "Off", "1 + 2"])
    #expect(UserFrameLines.next(after: "On", in: UserFrameLines.single) == "Off")
    #expect(UserFrameLines.next(after: "Off", in: UserFrameLines.single) == "On")
}

/// When the Autofocus tile's push is live: Push AF is Push MF with AF on, and Sony's FX5 guide
/// (Push AF is Push MF with AF on, and nothing with the lens's switch at MF).
@Suite("Push autofocus")
struct PushAutoFocusTests {
    private func state(can: Bool = true, mode: String? = nil, auto: Bool = false) -> CameraState {
        var s = CameraState()
        s.canAutoFocus = can
        s.focusMode = mode.map { Choice($0, options: ["AF", "MF"]) }
        s.focusIsAuto = auto
        return s
    }

    @Test("Live with no AF / MF (a Blackmagic camera's one-shot) or on MF; not on AF, while autofocusing, or without one")
    func live() {
        #expect(state().canPushAutoFocus)
        #expect(state(mode: "MF").canPushAutoFocus)
        #expect(!state(mode: "AF").canPushAutoFocus, "AF set: the press would be Push MF")
        #expect(!state(mode: "MF", auto: true).canPushAutoFocus, "the camera says it's autofocusing")
        #expect(!state(can: false, mode: "MF").canPushAutoFocus)
        #expect(["AF", "AF-C", "AF-S", "DMF"].allSatisfy(CameraState.isAutofocusMode))
        #expect(!["MF", "MF-R", "PF"].contains(where: CameraState.isAutofocusMode))
    }
}
