import Foundation
import Testing
@testable import CameraCore

// Moving a tile in edit mode: drop on a tile and they swap; tiles in the way make room; no tile changes size.

private func tile(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ kind: WidgetKind = .iso) -> PageWidget {
    PageWidget(kind: kind, cameraID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, x: x, y: y, w: w, h: h)
}

private func spot(_ layout: PageLayout, _ widget: PageWidget) -> GridSpot? {
    layout.widgets.first { $0.id == widget.id }.map { GridSpot(x: $0.x, y: $0.y) }
}

@Test func tilesOfOneSizeSwap() throws {
    let a = tile(0, 0, 1, 2), b = tile(1, 0, 1, 2), c = tile(2, 0, 1, 2), d = tile(3, 0, 1, 2)
    let layout = PageLayout(columns: 4, widgets: [a, b, c, d])
    let moved = try #require(layout.moving(a.id, to: GridSpot(x: 2, y: 0)))
    #expect(spot(moved, a) == GridSpot(x: 2, y: 0))
    #expect(spot(moved, c) == GridSpot(x: 0, y: 0))
    #expect(spot(moved, b) == GridSpot(x: 1, y: 0))
    #expect(spot(moved, d) == GridSpot(x: 3, y: 0))
}

@Test func aMoveIntoFreeCellsMovesNothingElse() throws {
    let a = tile(0, 0, 1, 2), b = tile(1, 0, 1, 2)
    let layout = PageLayout(columns: 4, widgets: [a, b])
    let moved = try #require(layout.moving(a.id, to: GridSpot(x: 2, y: 4)))
    #expect(spot(moved, a) == GridSpot(x: 2, y: 4))
    #expect(spot(moved, b) == GridSpot(x: 1, y: 0))
}

@Test func aBigTileSwapsWithTheTilesItLandsOn() throws {
    let big = tile(0, 2, 2, 2), d = tile(2, 0, 1, 2), e = tile(3, 0, 1, 2), f = tile(0, 0, 2, 2)
    let layout = PageLayout(columns: 4, widgets: [big, d, e, f])
    let moved = try #require(layout.moving(big.id, to: GridSpot(x: 2, y: 0)))
    #expect(spot(moved, big) == GridSpot(x: 2, y: 0))
    #expect(spot(moved, d) == GridSpot(x: 0, y: 2))
    #expect(spot(moved, e) == GridSpot(x: 1, y: 2))
    #expect(spot(moved, f) == GridSpot(x: 0, y: 0))
}

@Test func slidingPartlyOverATileSendsItIntoTheStripLeftBehind() throws {
    let wide = tile(0, 0, 2, 2), c = tile(2, 0, 1, 2), d = tile(3, 0, 1, 2)
    let layout = PageLayout(columns: 4, widgets: [wide, c, d])
    let moved = try #require(layout.moving(wide.id, to: GridSpot(x: 1, y: 0)))
    #expect(spot(moved, wide) == GridSpot(x: 1, y: 0))
    #expect(spot(moved, c) == GridSpot(x: 0, y: 0))
    #expect(spot(moved, d) == GridSpot(x: 3, y: 0))
}

@Test func aTileTooBigForThePlaceLeftMovesDownAndTakesWhatItLandsOnWithIt() throws {
    let small = tile(0, 0, 1, 2), b = tile(1, 0, 1, 2), big = tile(2, 0, 2, 2), below = tile(2, 2, 2, 2)
    let layout = PageLayout(columns: 4, widgets: [small, b, big, below])
    let moved = try #require(layout.moving(small.id, to: GridSpot(x: 2, y: 0)))
    #expect(spot(moved, small) == GridSpot(x: 2, y: 0))
    #expect(spot(moved, big) == GridSpot(x: 2, y: 2))
    #expect(spot(moved, below) == GridSpot(x: 2, y: 4))
    #expect(spot(moved, b) == GridSpot(x: 1, y: 0))
    #expect(moved.isValid)
}

@Test func aColumnMakesRoomByMovingDownIntoThePlaceLeft() throws {
    // T can't swap with A (A wouldn't fit in T's half row above D), so the column moves down one half row into it.
    let a = tile(0, 0, 1, 2), b = tile(0, 2, 1, 2), c = tile(0, 4, 1, 2), t = tile(0, 6, 1, 1), d = tile(0, 7, 1, 2)
    let layout = PageLayout(columns: 1, widgets: [a, b, c, t, d])
    let moved = try #require(layout.moving(t.id, to: GridSpot(x: 0, y: 0)))
    #expect([t, a, b, c, d].compactMap { spot(moved, $0)?.y } == [0, 1, 3, 5, 7])
    #expect(moved.rows == layout.rows)
}

@Test func aMoveStaysOnTheGrid() throws {
    let a = tile(0, 0, 2, 2)
    let layout = PageLayout(columns: 4, widgets: [a])
    #expect(layout.moving(a.id, to: GridSpot(x: 9, y: -3)).flatMap { spot($0, a) } == GridSpot(x: 2, y: 0))
    #expect(layout.moving(UUID(), to: GridSpot(x: 0, y: 0)) == nil)
}

@Test func theDropGoesWhereTheTilesCentreIs() {
    let t = tile(0, 0, 1, 2), big = tile(2, 0, 2, 4), half = tile(1, 0, 1, 1)
    let layout = PageLayout(columns: 4, widgets: [t, big, half])
    // Over another tile, however roughly aimed: that tile's top-left.
    #expect(layout.dropSpot(for: t.id, center: (2.9, 3.2), snapped: GridSpot(x: 2, y: 2)) == GridSpot(x: 2, y: 0))
    // A tile too wide to start there goes as far left as it must.
    let wide = tile(0, 6, 3, 2)
    let withWide = PageLayout(columns: 4, widgets: layout.widgets + [wide])
    #expect(withWide.dropSpot(for: wide.id, center: (3.5, 1), snapped: GridSpot(x: 2, y: 0)) == GridSpot(x: 1, y: 0))
    // Over empty cells: where it was snapped.
    #expect(layout.dropSpot(for: t.id, center: (0.5, 5), snapped: GridSpot(x: 0, y: 4)) == GridSpot(x: 0, y: 4))
    // Still over its own place: a nudge into free cells moves it, a nudge onto another tile doesn't.
    #expect(layout.dropSpot(for: t.id, center: (0.5, 1.9), snapped: GridSpot(x: 0, y: 1)) == GridSpot(x: 0, y: 1))
    #expect(layout.dropSpot(for: t.id, center: (0.9, 1), snapped: GridSpot(x: 1, y: 0)) == GridSpot(x: 0, y: 0))
}

@Test func noMoveEverResizesOrStacksTiles() {
    var random = SplitMix(seed: 0x7115)
    for _ in 0..<300 {
        let columns = [2, 4, 8].randomElement(using: &random)!
        var layout = PageLayout(columns: columns, widgets: [])
        for _ in 0..<Int.random(in: 3...14, using: &random) {
            let w = Int.random(in: 1...min(columns, 4), using: &random), h = Int.random(in: 1...4, using: &random)
            let at = layout.firstFreeSpot(w: w, h: h)
            layout.widgets.append(tile(at.x, at.y, w, h))
        }
        let picked = layout.widgets.randomElement(using: &random)!
        let target = GridSpot(x: Int.random(in: -1...columns, using: &random), y: Int.random(in: -1...(layout.rows + 2), using: &random))
        guard let moved = layout.moving(picked.id, to: target) else { Issue.record("no layout"); return }
        #expect(moved.isValid)
        #expect(Set(moved.widgets.map(\.id)) == Set(layout.widgets.map(\.id)))
        for before in layout.widgets {
            let after = moved.widgets.first { $0.id == before.id }!
            #expect(after.w == before.w && after.h == before.h)
        }
        let landed = moved.widgets.first { $0.id == picked.id }!
        #expect(landed.x == min(max(target.x, 0), columns - picked.w) && landed.y == max(target.y, 0))
    }
}

@MainActor @Test func theStoreMovesATileAndSavesIt() throws {
    let store = DashboardStore.preview(page: "A+B")
    let page = try #require(store.currentPage?.id)
    store.materializeLayout(page)
    let before = try #require(store.currentPage?.layout)
    let first = before.widgets[0]
    let other = try #require(before.widgets.first { $0.id != first.id && $0.w == first.w && $0.h == first.h })
    #expect(store.moveWidget(page, first.id, to: GridSpot(x: other.x, y: other.y)))
    let after = try #require(store.currentPage?.layout)
    #expect(after.widgets.first { $0.id == first.id }.map { GridSpot(x: $0.x, y: $0.y) } == GridSpot(x: other.x, y: other.y))
    #expect(after.widgets.first { $0.id == other.id }.map { GridSpot(x: $0.x, y: $0.y) } == GridSpot(x: first.x, y: first.y))
    #expect(!store.moveWidget(page, first.id, to: GridSpot(x: other.x, y: other.y)))  // already there
}

/// A small seeded generator, so a failure repeats.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
