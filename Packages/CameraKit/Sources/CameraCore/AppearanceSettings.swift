import Foundation

/// Settings → Appearance: the dashboard's colors and its tiles' corners.
///
/// Custom colors address outdoor use: Ink's dark tiles and gray text are hard to read in bright light, so white
/// tiles with black text on black are available as an alternative. Corners can go from round to square, so each tile
/// reads as its own key at a glance. Global, in an Appearance page, with a color picker. REC's red and each
/// camera's color never change. The highlight (the padlock and the Lock tile while locked, yellow) can be picked too.
///
/// Plain values, no SwiftUI: `DashboardUI` turns them into a `ThemeStyle` (`ThemeStore`).
public struct AppearanceSettings: Codable, Equatable, Sendable {
    /// A color as extended sRGB components: 0–1 is sRGB, and a Display P3 pick past sRGB's edge (iOS's picker hands
    /// those back) goes a little outside it. Kept as picked, so the picker shows what was picked and doesn't jump back
    /// to sRGB's nearest; the maths below clamps to sRGB.
    public struct RGB: Codable, Equatable, Hashable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = Self.clamped(red)
            self.green = Self.clamped(green)
            self.blue = Self.clamped(blue)
        }

        public init(white: Double) { self.init(red: white, green: white, blue: white) }

        public static let black = RGB(white: 0)
        public static let white = RGB(white: 1)

        /// `other` mixed in by `amount`: 0 is this color, 1 is `other`. Component by component, in sRGB.
        public func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount)
        }

        /// WCAG relative luminance: 0 for black, 1 for white.
        public var luminance: Double {
            func linear(_ value: Double) -> Double {
                let c = min(1, max(0, value))
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio with `other`, 1 (none) to 21 (black on white).
        public func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Black or white, whichever reads better on this color. At luminance 0.179 the two read the same.
        public var contrasting: RGB { luminance > 0.179 ? .black : .white }

        /// Light enough that black text reads better on it than white.
        public var isLight: Bool { luminance > 0.179 }

        /// Not a number is black; anything else stays within reach of sRGB (a wide pick is a few percent outside it).
        private static func clamped(_ value: Double) -> Double { value.isFinite ? min(2, max(-1, value)) : 0 }

        // MARK: Tiles' color picker (`ColourPickerPanel`): hue, saturation and brightness, and hex

        /// A color from hue (0–1, red at 0 and 1), saturation and brightness (0–1), in sRGB.
        public init(hue: Double, saturation: Double, brightness: Double) {
            let h = (hue.isFinite ? hue - hue.rounded(.down) : 0) * 6
            let s = min(max(saturation.isFinite ? saturation : 0, 0), 1)
            let v = min(max(brightness.isFinite ? brightness : 0, 0), 1)
            let sector = Int(h) % 6
            let f = h - Double(Int(h))
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch sector {
            case 0: self.init(red: v, green: t, blue: p)
            case 1: self.init(red: q, green: v, blue: p)
            case 2: self.init(red: p, green: v, blue: t)
            case 3: self.init(red: p, green: q, blue: v)
            case 4: self.init(red: t, green: p, blue: v)
            default: self.init(red: v, green: p, blue: q)
            }
        }

        /// Hue (0–1), saturation and brightness of this color as sRGB's edge (a wide pick is clamped first). A gray has
        /// hue 0.
        public var hsb: (hue: Double, saturation: Double, brightness: Double) {
            let r = min(1, max(0, red)), g = min(1, max(0, green)), b = min(1, max(0, blue))
            let high = max(r, g, b), low = min(r, g, b), range = high - low
            guard high > 0 else { return (0, 0, 0) }
            let saturation = range / high
            guard range > 0 else { return (0, 0, high) }
            var hue: Double
            if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
            hue /= 6
            if hue < 0 { hue += 1 }
            return (hue, saturation, high)
        }

        /// Six hex digits, sRGB clamped: "FFFFFF".
        public var hex: String {
            func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
        }

        /// From "FFCC00", "#ffcc00" or "FC0"; nil for anything else.
        public init?(hex: String) {
            var digits = hex.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("#") { digits.removeFirst() }
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            // Hex digits only: UInt32's parser would take "+12345".
            guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
            self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        }

        /// The same color to the picker's eye: every component within half an 8-bit step.
        public func matches(_ other: RGB) -> Bool {
            abs(red - other.red) < 0.5 / 255 + 1e-9 && abs(green - other.green) < 0.5 / 255 + 1e-9
                && abs(blue - other.blue) < 0.5 / 255 + 1e-9
        }
    }

    /// The three colors below replace the look's. Off goes back to the look and keeps them for next time, so a
    /// daylight set can be switched on outdoors and off again inside.
    public var customColors: Bool
    public var tile: RGB
    public var background: RGB
    public var text: RGB
    /// With custom colors on: the padlock's and the Lock tile's fill while the controls are locked, and the outline on a
    /// tile just added (`Theme.locked`). Starts on the standard yellow.
    public var highlight: RGB
    /// Tile corner radius in points; nil is the look's own (Ink's 12).
    public var corner: Double?
    /// Each tile outlined in its camera's color, as the Outline look drew them; off unless switched on.
    public var outlines: Bool
    /// The outline's width in points, 1 to 4 in halves.
    public var outlineWidth: Double {
        didSet { if outlineWidth != Self.outlineWidth(outlineWidth) { outlineWidth = Self.outlineWidth(outlineWidth) } }
    }
    /// Text Size: one size in every tile (the standard), or each tile's text growing with the tile (Dynamic;
    /// on a big iPad, titles, the ND − + and the Lock tile's padlock would otherwise read small).
    public var textSize: TextSize
    /// Text Size's slider: every tile's text, labels and small controls this many times the standard, 1 to 1.5 in
    /// tenths, on any screen. Dynamic grows a bigger tile's further from there.
    public var textScale: Double {
        didSet { if textScale != Self.textScale(textScale) { textScale = Self.textScale(textScale) } }
    }

    /// The slider's range: the standard to half again.
    public static let textScales: ClosedRange<Double> = 1...1.5

    /// The outline slider's range, and where it starts: the Outline look's 1.5 pt.
    public static let outlineWidths: ClosedRange<Double> = 1...4
    public static let standardOutlineWidth = 1.5

    /// `value` in halves, within the range; not a number is the standard.
    static func outlineWidth(_ value: Double) -> Double {
        let halves = value.isFinite ? (value * 2).rounded() / 2 : standardOutlineWidth
        return min(outlineWidths.upperBound, max(outlineWidths.lowerBound, halves))
    }

    /// `value` in tenths, within the range; not a number is the standard.
    static func textScale(_ value: Double) -> Double {
        let tenths = value.isFinite ? (value * 10).rounded() / 10 : 1
        return min(textScales.upperBound, max(textScales.lowerBound, tenths))
    }

    /// How big a tile's text, labels and small controls are. `standardized`: the same in every tile, whatever its size.
    /// `dynamic`: a bigger tile draws them bigger, as far as it keeps its shape (`Theme.zoom`).
    public enum TextSize: String, Codable, CaseIterable, Sendable {
        case standardized, dynamic
    }

    public init(customColors: Bool = false, tile: RGB = Self.daylight.tile, background: RGB = Self.daylight.background,
                text: RGB = Self.daylight.text, highlight: RGB = Self.standardHighlight, corner: Double? = nil,
                outlines: Bool = false, outlineWidth: Double = Self.standardOutlineWidth,
                textSize: TextSize = .standardized, textScale: Double = 1) {
        self.customColors = customColors
        self.tile = tile
        self.background = background
        self.text = text
        self.highlight = highlight
        self.corner = corner.map { min(Self.corners.upperBound, max(Self.corners.lowerBound, $0)) }
        self.outlines = outlines
        self.outlineWidth = Self.outlineWidth(outlineWidth)
        self.textSize = textSize
        self.textScale = Self.textScale(textScale)
    }

    /// The look, untouched.
    public static let standard = AppearanceSettings()

    /// What custom colors start on, and what Reset puts back: the outdoor set, white tiles and black text on black.
    public static let daylight = (tile: RGB.white, background: RGB.black, text: RGB.black)

    /// The standard look's highlight, the padlock's yellow (`SlotColor.yellow`), where a picked highlight starts.
    public static let standardHighlight = RGB(red: 0.98, green: 0.80, blue: 0.10)

    /// The corner radius the slider offers, square to rounder than Ink.
    public static let corners: ClosedRange<Double> = 0...20

    /// The dashboard's colors while custom colors are on; nil while they're off (the look's own).
    public var palette: AppearancePalette? {
        customColors ? AppearancePalette(tile: tile, background: background, text: text) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case customColors, tile, background, text, highlight, corner, outlines, outlineWidth, textSize, textScale
    }

    /// Fields a later build adds are missing from a saved one: each falls back to its default, never fails the whole.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(customColors: try c.decodeIfPresent(Bool.self, forKey: .customColors) ?? false,
                  tile: try c.decodeIfPresent(RGB.self, forKey: .tile) ?? Self.daylight.tile,
                  background: try c.decodeIfPresent(RGB.self, forKey: .background) ?? Self.daylight.background,
                  text: try c.decodeIfPresent(RGB.self, forKey: .text) ?? Self.daylight.text,
                  highlight: try c.decodeIfPresent(RGB.self, forKey: .highlight) ?? Self.standardHighlight,
                  corner: try c.decodeIfPresent(Double.self, forKey: .corner),
                  outlines: (try? c.decodeIfPresent(Bool.self, forKey: .outlines)).flatMap { $0 } ?? false,
                  outlineWidth: (try? c.decodeIfPresent(Double.self, forKey: .outlineWidth)).flatMap { $0 }
                    ?? Self.standardOutlineWidth,
                  // One a later build adds reads as standardized here.
                  textSize: (try? c.decodeIfPresent(String.self, forKey: .textSize)).flatMap { $0 }
                    .flatMap(TextSize.init(rawValue:)) ?? .standardized,
                  textScale: (try? c.decodeIfPresent(Double.self, forKey: .textScale)).flatMap { $0 } ?? 1)
    }
}

/// Every color the dashboard draws with, made from the three picked. The proportions come from Ink, whose grays are
/// the tile (0.07) mixed toward the text (0.96): a control 9 % of the way, a selected one or a switched-on tile 26 %,
/// secondary text 55 %. So any tile and text color gets the same steps between them that Ink has.
public struct AppearancePalette: Equatable, Sendable {
    public typealias RGB = AppearanceSettings.RGB

    public var background: RGB
    /// The top bar and the edit bar. The tile's color, not the background's: everything in the bar is drawn in the
    /// colors meant for a tile (text, controls, the link meter), and with black text on black it would vanish.
    public var chrome: RGB
    public var tile: RGB
    public var control: RGB
    public var controlSelected: RGB
    public var controlSelectedText: RGB
    public var text: RGB
    public var secondaryText: RGB
    public var timecode: RGB
    public var needle: RGB
    public var engaged: RGB
    public var dialRing: RGB
    public var dialTick: RGB
    public var track: RGB
    public var recFill: RGB
    public var accent: RGB
    public var accentText: RGB
    /// Text drawn straight on the background (the empty page, the welcome screen): the picked text where it reads
    /// there, else black or white.
    public var backgroundText: RGB
    public var backgroundSecondaryText: RGB

    public init(tile: RGB, background: RGB, text: RGB) {
        func toward(_ amount: Double) -> RGB { tile.mixed(with: text, amount) }
        self.background = background
        self.chrome = tile
        self.tile = tile
        self.control = toward(0.09)
        self.controlSelected = toward(0.26)
        self.controlSelectedText = toward(0.26).contrasting
        self.text = text
        self.secondaryText = toward(0.55)
        self.timecode = text
        self.needle = text
        self.engaged = toward(0.26)
        self.dialRing = toward(0.15)
        self.dialTick = toward(0.48)
        self.track = toward(0.11)
        // The unlit REC button: the tile's own color inside its red ring (Ink's is black on a near-black tile).
        self.recFill = tile
        self.accent = text
        self.accentText = text.contrasting
        let onBackground = text.contrast(with: background) >= 4.5 ? text : background.contrasting
        self.backgroundText = onBackground
        self.backgroundSecondaryText = background.mixed(with: onBackground, 0.6)
    }
}
