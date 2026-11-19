import Foundation
import Testing
import CameraCore
@testable import DashboardUI

/// An automatic page of several cameras holds a row in every column when any camera has a control there; a column
/// without it shows an empty tile, named only when the others have one control there.
@Suite("Held gaps")
struct HeldGapTests {
    let a = UUID(), b = UUID(), c = UUID()

    private func tile(_ kind: WidgetKind, _ camera: UUID, x: Int, y: Int, w: Int = 1, h: Int = 1) -> PageWidget {
        PageWidget(kind: kind, cameraID: camera, x: x, y: y, w: w, h: h)
    }

    @Test("A column without ND shows one tile over both ND rows, named No ND")
    func noND() {
        let layout = PageLayout(columns: 4, widgets: [
            tile(.ndPreset, a, x: 0, y: 0, w: 2), tile(.ndMinus, a, x: 0, y: 1), tile(.ndPlus, a, x: 1, y: 1),
            tile(.iso, a, x: 0, y: 2, w: 2),
            tile(.iso, b, x: 2, y: 2, w: 2),
        ])
        #expect(HeldGap.gaps(in: layout) == [HeldGap(x: 2, y: 0, w: 2, h: 2, name: "No ND")])
    }

    @Test("Where the others have several controls, the tile claims none")
    func severalControls() {
        let layout = PageLayout(columns: 4, widgets: [
            tile(.viewAssist, a, x: 0, y: 0), tile(.falseColor, a, x: 1, y: 0),
            tile(.iso, a, x: 0, y: 1, w: 2),
            tile(.iso, b, x: 2, y: 1, w: 2),
        ])
        #expect(HeldGap.gaps(in: layout) == [HeldGap(x: 2, y: 0, w: 2, h: 1, name: nil)])
    }

    @Test("Rows no camera uses and a page of one camera hold nothing")
    func nothingHeld() {
        let one = PageLayout(columns: 2, widgets: [tile(.iso, a, x: 0, y: 2, w: 2)])
        #expect(HeldGap.gaps(in: one).isEmpty)
        let full = PageLayout(columns: 4, widgets: [tile(.iso, a, x: 0, y: 0, w: 2), tile(.iso, b, x: 2, y: 0, w: 2)])
        #expect(HeldGap.gaps(in: full).isEmpty)
    }

    @Test("Each camera's gaps are its own: two columns without playback, one with")
    func eachColumn() {
        let layout = PageLayout(columns: 6, widgets: [
            tile(.playback, a, x: 0, y: 0, w: 2), tile(.record, a, x: 0, y: 1, w: 2),
            tile(.record, b, x: 2, y: 1, w: 2),
            tile(.record, c, x: 4, y: 1, w: 2),
        ])
        #expect(HeldGap.gaps(in: layout) == [HeldGap(x: 2, y: 0, w: 2, h: 1, name: "No Playback"),
                                            HeldGap(x: 4, y: 0, w: 2, h: 1, name: "No Playback")])
    }
}
