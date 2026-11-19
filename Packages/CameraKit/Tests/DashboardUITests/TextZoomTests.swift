import CoreGraphics
import Testing
import CameraCore
@testable import DashboardUI

/// Dynamic Text Size's rule (`TextZoom`, docs/design-style-guide.md § 1): a tile's scale grows with its height, in
/// eighths up to 1.5, and never changes the tile's shape or lays it out smaller than its smallest on the grid.
@MainActor
@Suite("Text Size")
struct TextZoomTests {
    /// Every tile size a page can make, near enough: phone half-columns to a 13-inch iPad's widest, 17 pt rows to tall.
    static let sizes: [CGSize] = stride(from: 90.0, through: 1300, by: 37).flatMap { w in
        stride(from: 17.0, through: 420, by: 7).map { CGSize(width: w, height: $0) }
    }

    @Test("Standardized draws every tile at 1")
    func standardized() {
        for kind in WidgetKind.allCases {
            for size in Self.sizes {
                #expect(TextZoom.zoom(kind: kind, size: size, textSize: .standardized) == 1)
            }
        }
    }

    @Test("The identity strip, REC, the dial, live view's picture, Playback and HaLow never grow")
    func exempt() {
        let exempt: [WidgetKind] = [.timecode, .label, .status, .battery, .media, .latency, .clipName, .record, .shutterDial, .liveView,
                                    .playback, .haLow]
        for kind in exempt {
            #expect(!TextZoom.zooms(kind))
            for size in Self.sizes { #expect(TextZoom.zoom(kind: kind, size: size, textSize: .dynamic) == 1) }
        }
    }

    @Test("A bigger tile keeps its shape, and is laid out no smaller than its smallest on the grid")
    func keepsShape() {
        for kind in WidgetKind.allCases where TextZoom.zooms(kind) {
            for switches in [true, false] {
                for size in Self.sizes {
                    let scale = TextZoom.zoom(kind: kind, size: size, switches: switches, textSize: .dynamic)
                    guard scale != 1 else { continue }
                    #expect(TextZoom.steps.contains(scale))
                    #expect(scale <= size.height / TextZoom.base)
                    let laidOut = CGSize(width: size.width / scale, height: size.height / scale)
                    #expect(TextZoom.shape(of: kind, in: laidOut, switches: switches)
                            == TextZoom.shape(of: kind, in: size, switches: switches),
                            "\(kind) at \(size) changes shape at \(scale)")
                    #expect(laidOut.width >= kind.smallestOnGrid.width - 0.01
                            && laidOut.height >= kind.smallestOnGrid.height - 0.01,
                            "\(kind) at \(size) is laid out below its smallest at \(scale)")
                }
            }
        }
    }

    @Test("An iPad mini's standard tile draws at 1; a 13-inch iPad's bigger tiles grow")
    func devices() {
        // The standard two-half-row tile on an iPad mini, where the type was drawn.
        #expect(TextZoom.zoom(kind: .lock, size: CGSize(width: 176, height: 66), textSize: .dynamic) == 1)
        #expect(TextZoom.zoom(kind: .ndPreset, size: CGSize(width: 176, height: 66), switches: false, textSize: .dynamic) == 1)
        // A 13-inch iPad's tile: ND without its step buttons, and Lock — both read small at the standard size.
        #expect(TextZoom.zoom(kind: .ndPreset, size: CGSize(width: 330, height: 92), switches: false, textSize: .dynamic) > 1)
        #expect(TextZoom.zoom(kind: .lock, size: CGSize(width: 330, height: 92), textSize: .dynamic) > 1)
        // Never past the largest step.
        #expect(TextZoom.zoom(kind: .wbPreset, size: CGSize(width: 1300, height: 420), textSize: .dynamic) == TextZoom.steps[0])
    }

    @Test("A White Balance tile's form at a scale is the standard tile's at its size over the scale")
    func whiteBalanceForm() {
        for size in Self.sizes {
            for scale in TextZoom.steps {
                let standard = WhiteBalanceSlidersTile.form(for: CGSize(width: size.width / scale, height: size.height / scale),
                                                            showsTint: true)
                let scaled = WhiteBalanceSlidersTile.form(for: size, showsTint: true, scale: scale)
                #expect(scaled.stacked == standard.stacked && scaled.tint == standard.tint
                        && scaled.sideBySide == standard.sideBySide && scaled.squeezed == standard.squeezed)
                #expect(abs(scaled.line - standard.line * scale) < 0.001)
            }
        }
    }
}
