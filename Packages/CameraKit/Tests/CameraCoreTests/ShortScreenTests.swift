import Foundation
import Testing
@testable import CameraCore

// A phone on its side shows a page of several cameras one camera at a time, each as wide as the screen:
// its 4-wide part of the page, edited straight back into the page, or for three or more cameras its
// 4-wide block changed where the page was.

@MainActor private func profile(_ store: DashboardStore) -> (UUID) -> CameraProfile? {
    let profiles = Dictionary(uniqueKeysWithValues: store.cameras.map { ($0.id, $0.templateProfile) })
    return { id in profiles[id] ?? nil }
}

@Test func aCameraCroppedFromAPageKeepsItsArrangementAndSaysWhereItWas() throws {
    let a = UUID(), b = UUID()
    let page = PageLayout(columns: 8, widgets: LayoutTemplates.wide(camera: a) + LayoutTemplates.wide(camera: b, x: 4))
    let crop = try #require(page.cropped(to: b))
    #expect(crop.origin == GridSpot(x: 4, y: 0))
    #expect(crop.layout.columns == 4)
    let bTiles = page.widgets.filter { $0.cameraID == b }
    #expect(crop.layout.widgets.count == bTiles.count)
    for tile in crop.layout.widgets {
        let original = try #require(bTiles.first { $0.id == tile.id })
        #expect(tile.x == original.x - 4 && tile.y == original.y && tile.w == original.w && tile.h == original.h)
    }
    #expect(page.cropped(to: UUID()) == nil)
}

@MainActor @Test func aShortScreenShowsEachOfTwoCamerasAsItsPartOfThePage() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let a = store.cameras[0].id, b = store.cameras[1].id
    // Automatic: each camera's 4-wide block, drawn but not edited through (editing makes the page explicit first).
    let automatic = LayoutTemplates.shortScreen(camera: b, cameras: [a, b], profile: profile(store), page: nil)
    #expect(automatic.layout.columns == LayoutTemplates.wideColumns && automatic.origin == nil)
    // Edit mode makes it explicit: the same blocks side by side, so what's shown doesn't move, and now edits go through.
    store.materializeLayout(page)
    let layout = try #require(store.currentPage?.layout)
    let explicit = LayoutTemplates.shortScreen(camera: b, cameras: [a, b], profile: profile(store), page: layout)
    #expect(explicit.origin == GridSpot(x: 4, y: 0))
    #expect(explicit.layout.widgets.map { "\($0.kind) \($0.x) \($0.y) \($0.w) \($0.h)" }.sorted()
            == automatic.layout.widgets.map { "\($0.kind) \($0.x) \($0.y) \($0.w) \($0.h)" }.sorted())
}

@MainActor @Test func aShortScreenShowsEachOfFourCamerasAsItsWideBlockWithThePagesChanges() throws {
    let store = DashboardStore.preview(page: "All")
    let page = try #require(store.currentPage?.id)
    let ids = store.cameras.map(\.id)
    store.materializeLayout(page)   // four cameras: two columns each
    let narrow = try #require(store.currentPage?.layout)
    #expect(narrow.columns == 8)
    // The page loses camera A's ISO tile: A's wide block on the short screen loses it too.
    let iso = try #require(narrow.widgets.first { $0.cameraID == ids[0] && $0.kind == .iso })
    store.removeWidget(page, iso.id)
    let changed = try #require(store.currentPage?.layout)
    let shown = LayoutTemplates.shortScreen(camera: ids[0], cameras: ids, profile: profile(store), page: changed)
    #expect(shown.layout.columns == LayoutTemplates.wideColumns)
    #expect(shown.origin == nil)   // not the page's arrangement: edit mode edits A's 2-wide part of the page instead
    #expect(!shown.layout.widgets.contains { $0.kind == .iso })
    #expect(shown.layout.widgets.allSatisfy { $0.cameraID == ids[0] })
    #expect(shown.layout.widgets.allSatisfy { shown.layout.fits($0) })
    // That 2-wide part, edited through its own origin.
    let part = try #require(changed.cropped(to: ids[1]))
    #expect(part.layout.columns == 2 && part.origin == GridSpot(x: 2, y: 0))
}

@MainActor @Test func aMoveOnOneCamerasPartGoesBackToThePageThere() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let b = store.cameras[1].id
    store.materializeLayout(page)
    let crop = try #require(store.currentPage?.layout?.cropped(to: b))
    let origin = try #require(crop.origin)
    // Swap B's first tile with another of its size, as the cropped view would: its spot, moved by the origin.
    let first = crop.layout.widgets[0]
    let other = try #require(crop.layout.widgets.first { $0.id != first.id && $0.w == first.w && $0.h == first.h })
    #expect(store.moveWidget(page, first.id, to: GridSpot(x: other.x + origin.x, y: other.y + origin.y)))
    let after = try #require(store.currentPage?.layout)
    let moved = try #require(after.widgets.first { $0.id == first.id })
    let swapped = try #require(after.widgets.first { $0.id == other.id })
    #expect(moved.x == other.x + origin.x && moved.y == other.y + origin.y)
    #expect(swapped.x == first.x + origin.x && swapped.y == first.y + origin.y)
    // Camera A's tiles never moved.
    let before = LayoutTemplates.materialize(cameraIDs: store.cameras.prefix(2).map(\.id), profile: profile(store))
    for tile in after.widgets where tile.cameraID == store.cameras[0].id {
        #expect(before.widgets.contains { $0.kind == tile.kind && $0.x == tile.x && $0.y == tile.y })
    }
}

@MainActor @Test func anAddedTileStaysInItsCamerasColumns() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    let a = store.cameras[0].id, b = store.cameras[1].id
    store.materializeLayout(page)
    // A hole in A's columns near the top: B's new tile must not go there.
    let aTile = try #require(store.currentPage?.layout?.widgets.first { $0.cameraID == a && $0.kind == .iso })
    store.removeWidget(page, aTile.id)
    store.addWidget(page, kind: .zebra, cameraID: b)
    let layout = try #require(store.currentPage?.layout)
    let added = try #require(layout.widgets.first { $0.id == store.addedWidgetID })
    let span = try #require(layout.columnSpan(of: b))
    #expect(added.x >= span.lowerBound && added.maxX <= span.upperBound)
    #expect(layout.fits(added))
}
