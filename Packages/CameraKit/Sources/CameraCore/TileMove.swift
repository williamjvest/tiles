import Foundation

// Moving a tile in edit mode: drop it on another tile and the two swap; drop it where other tiles are in its way and
// they make room, the way icons do on an iPhone's Home Screen, shown while the tile is still held. No tile ever
// changes size to make room — resizing stays the corner's drag.

/// A tile's top-left on a page's grid, in columns and half-rows.
public struct GridSpot: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

extension PageLayout {
    /// Where a dragged tile goes if it's let go now. `center` is the dragged tile's center and `snapped` its top-left
    /// rounded to the grid, both in cells (columns, half-rows) of this layout as it was before the drag began:
    /// - over another tile, it goes to that tile's top-left (as far left as it must to stay on the grid), so the two
    ///   swap however roughly it was aimed;
    /// - over empty cells, to where it was snapped;
    /// - still over its own place, it stays put, unless it was only nudged into free cells.
    public func dropSpot(for id: UUID, center: (x: Double, y: Double), snapped: GridSpot) -> GridSpot {
        guard let tile = widgets.first(where: { $0.id == id }) else { return snapped }
        func isUnderCenter(_ widget: PageWidget) -> Bool {
            center.x >= Double(widget.x) && center.x < Double(widget.maxX)
                && center.y >= Double(widget.y) && center.y < Double(widget.maxY)
        }
        let rightmost = max(columns - tile.w, 0)
        if let under = widgets.first(where: { $0.id != id && isUnderCenter($0) }) {
            return GridSpot(x: min(under.x, rightmost), y: under.y)
        }
        let spot = GridSpot(x: min(max(snapped.x, 0), rightmost), y: max(snapped.y, 0))
        guard isUnderCenter(tile) else { return spot }
        var nudged = tile
        nudged.x = spot.x
        nudged.y = spot.y
        return fits(nudged) ? spot : GridSpot(x: tile.x, y: tile.y)
    }

    /// This layout with tile `id` moved to `spot` (kept on the grid), its size unchanged, and the tiles in its way
    /// moved out of it:
    /// - into the place it left, all together and still arranged as they were, when they fit there (a swap);
    /// - otherwise straight down, just below it, along with anything they then land on: they make room, never shrink.
    /// Every other tile stays where it is. Nil if the page has no such tile.
    public func moving(_ id: UUID, to spot: GridSpot) -> PageLayout? {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return nil }
        let original = widgets[index]
        var moved = original
        moved.x = min(max(spot.x, 0), max(columns - original.w, 0))
        moved.y = max(spot.y, 0)
        var result = self
        result.widgets[index] = moved
        let inTheWay = Set(widgets.filter { $0.id != id && $0.overlaps(moved) }.map(\.id))
        guard !inTheWay.isEmpty else { return result }
        for (dx, dy) in Self.swapShifts(from: original, to: moved) {
            var swapped = result
            for slot in swapped.widgets.indices where inTheWay.contains(swapped.widgets[slot].id) {
                swapped.widgets[slot].x += dx
                swapped.widgets[slot].y += dy
            }
            if swapped.isValid { return swapped }
        }
        return result.pushingDown(clearOf: id)
    }

    /// How far the tiles in the way shift to take the place the moved tile left: back by the whole move; or, where it
    /// only slid partly over them, by its own width or height, into the strip it uncovered.
    static func swapShifts(from original: PageWidget, to moved: PageWidget) -> [(Int, Int)] {
        let dx = moved.x - original.x, dy = moved.y - original.y
        var shifts = [(-dx, -dy)]
        if original.overlaps(moved) {
            let sx = dx == 0 ? 0 : -dx.signum() * max(abs(dx), original.w)
            let sy = dy == 0 ? 0 : -dy.signum() * max(abs(dy), original.h)
            shifts.append((sx, sy))
        }
        return shifts
    }

    /// Every tile on the grid, and none on another.
    var isValid: Bool {
        for (index, tile) in widgets.enumerated() {
            guard tile.x >= 0, tile.y >= 0, tile.maxX <= columns else { return false }
            if widgets[(index + 1)...].contains(where: { $0.overlaps(tile) }) { return false }
        }
        return true
    }

    /// Tile `id` stays put. Every other tile that lands on it, or on a tile moved for it, moves down just clear of it,
    /// the top ones first, so a stack stays a stack and a row stays a row.
    func pushingDown(clearOf id: UUID) -> PageLayout {
        guard let fixed = widgets.first(where: { $0.id == id }) else { return self }
        var placed = [fixed]
        var moved: [UUID: PageWidget] = [:]
        for var tile in widgets.filter({ $0.id != id }).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            while let bottom = placed.filter({ $0.overlaps(tile) }).map(\.maxY).max() { tile.y = bottom }
            placed.append(tile)
            moved[tile.id] = tile
        }
        var result = self
        result.widgets = widgets.map { moved[$0.id] ?? $0 }
        return result
    }
}
