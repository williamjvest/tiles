import SwiftUI
import CameraCore

// MARK: - Text Size: Standardized | Dynamic (Settings → Appearance)

/// Dynamic Text Size: Standardized draws every tile exactly as before. Dynamic gives each tile a
/// scale, `tileScale`: its type, insets, controls and symbols are drawn that many times the standard, at real sizes so
/// they stay sharp, and the heights and widths it compares its size with are that many times larger too. So a tile at
/// scale k lays out exactly as the standard tile at its size over k, only k times bigger, and fits wherever that does.
///
/// The rule, per tile:
/// - It grows with the tile's height, from 1 at `base` (a standard two-half-row tile on an iPad mini, 66 pt, where the
///   type was drawn) to `steps.first` (1.5).
/// - It never changes the tile's shape: a tile with two rows, full-size switches, or Temp and Tint keeps them
///   (`shape(of:in:switches:)`); switches may move from a column to a row along the bottom, where they're full size too.
///   It takes the largest step at which the smaller layout is still the same shape, and never lays a tile out smaller
///   than its smallest on the grid (`smallestOnGrid`), where the gallery has checked it. So a tile whose shape hangs on
///   its width grows less, and one on its smallest shape anyway grows freely.
/// - Tiles that already size their content to the tile, or drop parts as they shrink, stay at 1: the identity strip
///   (camera letter, battery and card, timecode, latency, naming), REC, the shutter dial, live view's picture, Playback
///   and HaLow.
/// - Steps of an eighth, so tiles of one size match and a resize changes it in visible steps.
/// - Edit mode's outlines, chips and badges stay at 1: they're the page's, not the tile's.
@MainActor
enum TextZoom {
    /// The height at which a tile draws at 1: a standard two-half-row tile on an iPad mini, where the type was drawn.
    static let base: CGFloat = 66
    /// Largest first.
    static let steps: [CGFloat] = [1.5, 1.375, 1.25, 1.125]

    /// The scale for a tile of `kind` at `size`, with Text Size `textSize`. 1: drawn as Standardized. `switches`: the
    /// tile has mode switches for its camera; only then does where they'd go decide its shape.
    static func zoom(kind: WidgetKind, size: CGSize, switches: Bool = true,
                     textSize: AppearanceSettings.TextSize = ThemeStore.shared.appearance.textSize) -> CGFloat {
        guard textSize == .dynamic, size.width > 0, size.height > 0,
              let shape = shape(of: kind, in: size, switches: switches) else { return 1 }
        let smallest = kind.smallestOnGrid
        // Never laid out smaller than the tile is checked at (its smallest on the grid, `smallestOnGrid`): there the
        // gallery's overflow audit has seen it fit.
        let grow = min(size.height / base, size.width / smallest.width, size.height / smallest.height)
        for step in steps where step <= grow {
            let laidOut = CGSize(width: size.width / step, height: size.height / step)
            if Self.shape(of: kind, in: laidOut, switches: switches) == shape { return step }
        }
        return 1
    }

    /// Whether `kind` ever draws bigger with Dynamic.
    static func zooms(_ kind: WidgetKind) -> Bool { shape(of: kind, in: CGSize(width: 1, height: 1)) != nil }

    /// What decides a tile's shape at `size`: its thresholds, each crossed or not. Two sizes with the same shape lay the
    /// tile out the same way, larger or smaller. nil: the tile doesn't zoom. Mirrors the thresholds in the tiles
    /// themselves (`TileFrame`, `WhiteBalanceSlidersTile.form`, the Iris, ND −/+, toggle and Live View tiles).
    static func shape(of kind: WidgetKind, in size: CGSize, switches: Bool = true) -> [Bool]? {
        let (w, h) = (size.width, size.height)
        let spec = kind.spec
        switch kind {
        case .timecode, .label, .status, .battery, .media, .latency, .clipName, .record, .recordAll, .shutterDial, .liveView, .playback, .haLow, .webGUI:
            return nil
        case .wbSliders:
            let form = WhiteBalanceSlidersTile.form(for: size, showsTint: true)
            return [form.stacked, form.tint, form.sideBySide, form.squeezed]
        case .iris:
            // Two rows from 56 pt; the ‹ › step buttons where the track keeps 150 pt (one line: caption and readout
            // beside it take about 130).
            let oneLine = h < (spec.oneLineBelow ?? 56) + Theme.captionRowGrowth
            return [oneLine, oneLine ? w >= 280 : w >= 170]
        case .ndMinus, .ndPlus:
            return [h < 2 * Theme.insetV + Theme.captionRow + 6]
        case .liveViewButton:
            return [h >= 40]
        case .colorBars, .falseColor, .look, .sensorFlip, .hdmiInfo, .gridLines, .viewAssist, .zebra, .focusAssist,
             .frameGuides, .cleanFeed, .statusText, .monitoring, .cameraMenu, .call, .lock, .autoFocus, .grabStill:
            // One-button tiles: a shorter label below 34 pt.
            return [h < 34]
        default:
            // Captioned tiles (`TileFrame`): one line or two (the LUT tile goes to one line at either threshold,
            // depending on its switches), and whether the switches are full size, in a column or along the bottom, or
            // small in the header. A column becoming a bottom row keeps them full size, so it's the same shape.
            let column = Theme.insetV + Theme.captionRow + Theme.captionGap + 34
            let fullSwitches = switches
                && ((spec.trailingFrom.map { w >= $0 } ?? false) && h >= column || (spec.footerFrom.map { h >= $0 } ?? false))
            let grow = Theme.captionRowGrowth
            return [h < Theme.oneLineBelow + grow, h < (spec.oneLineBelow ?? Theme.oneLineBelow) + grow, fullSwitches,
                    spec.captionFrom.map { w >= $0 * Theme.textBump } ?? false]
        }
    }
}

extension WidgetKind {
    /// The smallest this tile is on the grid, and the smallest it's checked at: its minimum columns of a phone's half width
    /// (180 pt), on its minimum half-rows at the 17 pt floor Fit to Screen can shrink rows to. The gallery's last column
    /// draws every kind there, and its overflow audit fails on anything cut off (docs/design-style-guide.md § 1).
    public var smallestOnGrid: CGSize {
        let w = CGFloat(minimumSize.w), h = CGFloat(minimumSize.h)
        return CGSize(width: w * 180 + (w - 1) * Theme.gap, height: h * 17 + (h - 1) * Theme.gap)
    }
}

extension CameraState {
    /// Whether a tile of `kind` has mode switches on this camera: the ones that do say so with a switch caption
    /// (`TileFrame.switchCaption`), and these are their conditions. `ndStep`: the ND tile's step buttons are on.
    @MainActor
    func hasModeSwitches(_ kind: WidgetKind, ndStep: Bool) -> Bool {
        switch kind {
        case .ndPreset: ndStep
        case .shutterValue: shutterMode != nil
        case .frameRate: frameRate?.variable != nil
        case .iso: baseISO != nil
        case .lut: look != nil || LUTTile.falseColorOption(in: self) != nil
        default: false
        }
    }
}

/// Dynamic Text Size on one tile (`WidgetView`): its scale into the environment, `tileScale`, for everything in it.
/// With Standardized, or a tile that stays at 1, the tile is left exactly as it was: no reader, nothing set.
struct TileScaling: ViewModifier {
    let kind: WidgetKind
    var switches: Bool

    func body(content: Content) -> some View {
        if ThemeStore.shared.appearance.textSize == .dynamic, TextZoom.zooms(kind) {
            GeometryReader { geo in
                content
                    .environment(\.tileScale, TextZoom.zoom(kind: kind, size: geo.size, switches: switches))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            content
        }
    }
}
