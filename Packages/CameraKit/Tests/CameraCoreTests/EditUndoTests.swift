import Foundation
import Testing
@testable import CameraCore
import CameraKitTestSupport

// Undo in edit mode, and Test Mode saying when a camera goes live or offline.

@MainActor @Test func undoPutsThePageBackOneEditAtATime() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    store.beginEditing(page)
    #expect(store.editUndo.isEmpty)
    let start = try #require(store.currentPage)

    let first = start.layout!.widgets[0]
    let other = try #require(start.layout!.widgets.first { $0.id != first.id && $0.w == first.w && $0.h == first.h })
    #expect(store.moveWidget(page, first.id, to: GridSpot(x: other.x, y: other.y)))
    let afterMove = try #require(store.currentPage)
    store.removeWidget(page, other.id)
    store.setPageScrolls(page, true)
    #expect(store.editUndo.count == 3)

    store.undoEdit()
    #expect(store.currentPage?.isScrolling == false)
    store.undoEdit()
    #expect(store.currentPage == afterMove)
    store.undoEdit()
    #expect(store.currentPage == start)
    #expect(store.editUndo.isEmpty)
    store.undoEdit()   // nothing left: nothing changes
    #expect(store.currentPage == start)
}

@MainActor @Test func aRefusedEditLeavesNothingToUndo() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    store.beginEditing(page)
    let layout = try #require(store.currentPage?.layout)
    var clash = layout.widgets[0]
    clash.x = layout.widgets[1].x
    clash.y = layout.widgets[1].y
    #expect(!store.placeWidget(page, clash))   // overlaps: refused
    #expect(!store.moveWidget(page, layout.widgets[0].id, to: GridSpot(x: layout.widgets[0].x, y: layout.widgets[0].y)))
    store.setPageScrolls(page, store.currentPage?.isScrolling ?? false)   // no change
    #expect(store.editUndo.isEmpty)
}

@MainActor @Test func undoIsForgottenWhenEditingEndsAndIsBounded() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    store.beginEditing(page)
    for n in 0..<(DashboardStore.editUndoLimit + 10) { store.setPageScrolls(page, n % 2 == 0) }
    #expect(store.editUndo.count == DashboardStore.editUndoLimit)
    store.finishEditing(page)
    #expect(store.editUndo.isEmpty)
}

/// Test Mode says when a camera comes back (it takes over from its demo) and when it drops out (its demo takes over);
/// a camera's first report isn't a change, and outside Test Mode nothing is said.
@MainActor @Test func testModeSaysWhenACameraGoesLiveOrOffline() async throws {
    let saved = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "192.0.2.1"),
                            connection: .blackmagic(BlackmagicConnection(host: "192.0.2.1")))
    let store = DashboardStore(cameras: [saved], pages: [CameraPage(name: "A", cameraIDs: [saved.slot.id])],
                               startCameras: true,
                               makeBackend: { _, _ in MockCameraBackend(state: MockCameraBackend.pyxisSampleState(), heartbeat: nil) })
    store.testMode = true
    let camera = store.cameras[0]
    #expect(await waitUntilMain { camera.state.connection.isControllable })
    #expect(store.testModeNotice == nil)

    camera.suspend()
    #expect(await waitUntilMain { store.testModeNotice?.isLive == false })
    #expect(store.testModeNotice?.label == "A" && store.testModeNotice?.cameraID == camera.id)
    let demo = try #require(store.previewController(for: camera))
    #expect(demo.isDemo)

    camera.resume()
    #expect(await waitUntilMain { store.testModeNotice?.isLive == true })
    #expect(store.previewController(for: camera) == nil)   // the camera took over; its demo is gone

    let notice = try #require(store.testModeNotice)
    store.dismissTestModeNotice(notice.id)
    #expect(store.testModeNotice == nil)
    store.testMode = false
    camera.suspend()
    #expect(await waitUntilMain { !camera.state.connection.isControllable })
    try await Task.sleep(for: .milliseconds(200))
    #expect(store.testModeNotice == nil)
}
