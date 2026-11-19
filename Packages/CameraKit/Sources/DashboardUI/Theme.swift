import SwiftUI
import CameraCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A look for the dashboard: its colors, how a tile says which camera it's for, and its type.
public struct ThemeStyle: Sendable {
    /// How a tile says which camera it's for: a border in the camera's color, or its captions in that color.
    public enum Identity: Sendable { case outline, ink }

    public var name: String
    public var background: Color
    public var chrome: Color
    public var tile: Color
    public var control: Color
    public var controlSelected: Color
    public var text: Color
    public var secondaryText: Color
    public var timecode: Color
    public var recording: Color
    public var needle: Color
    public var engaged: Color
    /// The shutter dial's ring and ticks, slider tracks, the unlit REC button's fill.
    public var dialRing: Color
    public var dialTick: Color
    public var track: Color
    public var recFill: Color
    public var gap: CGFloat
    public var corner: CGFloat
    /// The tile outline's width, where tiles have one (`drawsOutline`).
    public var border: CGFloat
    public var identity: Identity
    /// Values and readouts: SF Mono, or another design with steady (tabular) digits.
    public var valueDesign: Font.Design
    /// Takes each value weight down this many steps (bold to medium at 2).
    public var valueLighter: Int
    public var captionFont: Font
    public var captionTracking: CGFloat
    /// The caption font's weight, for its sizes under Dynamic Text Size (`Theme.caption(_:)`).
    public var captionWeight: Font.Weight = .bold
    /// The chosen page tab and its text; a chosen segment's text.
    public var accent: Color
    public var accentText: Color
    public var controlSelectedText: Color
    /// Full strength, for what sits on a tile as a mark rather than text: a slider's knob and ticks, the Live View
    /// launcher's camera, an edit-mode outline. White in both looks; the text color with custom colors, where a
    /// white knob on a white tile would leave only its shadow.
    public var strong: Color = .white
    /// Text straight on the background (the empty page, the welcome screen); nil is `text`. Custom colors set it
    /// when the text doesn't read on the background: black text on a black background.
    public var backgroundText: Color? = nil
    public var backgroundSecondaryText: Color? = nil
    /// Settings → Appearance's tile outlines, on a look that has none of its own.
    public var outlines = false

    /// Each tile outlined in its camera's color, `border` wide: the Outline look always, any look with Appearance's on.
    public var drawsOutline: Bool { identity == .outline || outlines }

    /// Ink: borderless tiles on true black, each tile's captions in its camera's color, SF Pro with steady
    /// digits.
    public static let ink = ThemeStyle(
        name: "ink",
        background: .black, chrome: .black, tile: Color(white: 0.07), control: Color(white: 0.15),
        controlSelected: Color(white: 0.3), text: Color(white: 0.96), secondaryText: Color(white: 0.56),
        timecode: Color(white: 0.96), recording: Color(red: 1.0, green: 0.27, blue: 0.23), needle: Color(white: 0.96),
        engaged: Color(white: 0.3),
        dialRing: Color(white: 0.2), dialTick: Color(white: 0.5), track: Color(white: 0.17), recFill: .black,
        gap: 6, corner: 12, border: 0, identity: .ink, valueDesign: .default, valueLighter: 2,
        captionFont: .system(size: 10, weight: .bold), captionTracking: 1.4,
        accent: Color(white: 0.96), accentText: .black, controlSelectedText: .white)

    /// The Outline look, matched to the inspiration image in the vault
    /// (`02-Projects/Active/Camera-Control-App/assets/dashboard-inspo.png`): camera-colored outlines, SF Mono.
    /// `CC_SNAPSHOT_STYLE=outline dashboard-snapshot …` renders it.
    public static let outline = ThemeStyle(
        name: "outline",
        background: Color(red: 0.11, green: 0.11, blue: 0.11), chrome: Color(red: 0.14, green: 0.14, blue: 0.14),
        tile: Color(red: 0.155, green: 0.155, blue: 0.155), control: Color(white: 0.24), controlSelected: Color(white: 0.44),
        text: .white, secondaryText: Color(white: 0.66), timecode: Color(red: 0.27, green: 0.87, blue: 0.40),
        recording: Color(red: 0.94, green: 0.24, blue: 0.22), needle: Color(red: 0.22, green: 0.52, blue: 1.0),
        engaged: Color(red: 0.38, green: 0.22, blue: 0.68),
        dialRing: Color(white: 0.34), dialTick: Color(white: 0.6), track: Color(white: 0.3), recFill: Color(white: 0.17),
        gap: 8, corner: 9, border: 1.5, identity: .outline, valueDesign: .monospaced, valueLighter: 0,
        captionFont: .system(size: 10, weight: .heavy), captionTracking: 0.6, captionWeight: .heavy,
        accent: Color(red: 0.22, green: 0.52, blue: 1.0), accentText: .white, controlSelectedText: .white)

    public static let all: [ThemeStyle] = [.ink, .outline]

    /// This look with Settings → Appearance on top: its corner radius and tile outlines, and with custom colors on,
    /// every color made from the three picked (`AppearancePalette`). REC's red, the camera colors and the Lock color
    /// stay.
    public func applying(_ appearance: AppearanceSettings) -> ThemeStyle {
        var style = self
        if let corner = appearance.corner {
            style.corner = CGFloat(min(AppearanceSettings.corners.upperBound, max(AppearanceSettings.corners.lowerBound, corner)))
        }
        if appearance.outlines {
            style.outlines = true
            style.border = CGFloat(appearance.outlineWidth)
        }
        guard let p = appearance.palette else { return style }
        style.background = Color(p.background)
        style.chrome = Color(p.chrome)
        style.tile = Color(p.tile)
        style.control = Color(p.control)
        style.controlSelected = Color(p.controlSelected)
        style.controlSelectedText = Color(p.controlSelectedText)
        style.text = Color(p.text)
        style.secondaryText = Color(p.secondaryText)
        style.timecode = Color(p.timecode)
        style.needle = Color(p.needle)
        style.engaged = Color(p.engaged)
        style.dialRing = Color(p.dialRing)
        style.dialTick = Color(p.dialTick)
        style.track = Color(p.track)
        style.recFill = Color(p.recFill)
        style.accent = Color(p.accent)
        style.accentText = Color(p.accentText)
        style.strong = Color(p.text)
        style.backgroundText = Color(p.backgroundText)
        style.backgroundSecondaryText = Color(p.backgroundSecondaryText)
        return style
    }
}

extension Color {
    init(_ rgb: AppearanceSettings.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

extension AppearanceSettings.RGB {
    /// A picked color as extended sRGB. iOS's picker hands back Display P3, which can fall a little outside sRGB: kept
    /// as it is (`RGB`'s maths clamps it), so the picker gets back exactly what it gave.
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
}

/// The look in use, and Settings → Appearance on top of it. Every `Theme` token reads `style` through here, and it's
/// observable, so any view that drew with a token draws again when the appearance changes: the page follows the color
/// picker as it moves, with nothing rebuilt (an `.id()` rebuild would also close the Settings sheet it's open in).
@Observable
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()

    /// The look underneath: Ink, unless a snapshot asks for another (CC_SNAPSHOT_STYLE).
    public var base: ThemeStyle = .ink {
        didSet { style = base.applying(appearance) }
    }

    public var appearance: AppearanceSettings = .standard {
        didSet {
            guard appearance != oldValue else { return }
            style = base.applying(appearance)
            palette = appearance.palette
            legibleShades = [:]
            save()
        }
    }

    @ObservationIgnored private var palette: AppearancePalette?
    @ObservationIgnored private var legibleShades: [Color: Color] = [:]

    /// `Theme.legible`. Reading `appearance` is what redraws a caption when the colors change; each color's shade is
    /// kept until they do, so a hit costs a lookup, not a color resolve.
    func legible(_ tint: Color) -> Color {
        guard appearance.customColors, let palette else { return tint }
        if let known = legibleShades[tint] { return known }
        let rgb = AppearanceSettings.RGB(tint)
        var shade = rgb
        for step in 1...10 where shade.contrast(with: palette.tile) < 3 {
            shade = rgb.mixed(with: palette.text, Double(step) / 10)
        }
        let legible = shade == rgb ? tint : Color(shade)
        legibleShades[tint] = legible
        return legible
    }

    /// `Theme.locked`: the picked highlight while custom colors are on, else the standard yellow. Reading `appearance`
    /// is what redraws the padlock when it changes.
    var highlight: Color { appearance.customColors ? Color(appearance.highlight) : SlotColor.yellow.color }
    var highlightText: Color { appearance.customColors ? Color(appearance.highlight.contrasting) : .black }

    /// `base` with `appearance` applied: what every token reads.
    public private(set) var style: ThemeStyle = .ink

    @ObservationIgnored private var defaults: UserDefaults?
    static let defaultsKey = "appearance.v1"

    /// Reads the saved appearance, and saves every change after. Only the app calls it, at launch before the first
    /// frame, so tests and dashboard-snapshot draw the standard look whatever the Mac running them has saved.
    public func load(from defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            appearance = saved
        }
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public enum Theme {
    /// The look in use (`ThemeStore`): Ink, with Settings → Appearance on top. Setting it sets the look underneath,
    /// as dashboard-snapshot's CC_SNAPSHOT_STYLE does.
    public static var style: ThemeStyle {
        get { ThemeStore.shared.style }
        set { ThemeStore.shared.base = newValue }
    }

    /// The look without custom colors, for text on what the system draws: forms, sheets, popovers. Those rows and
    /// backgrounds are the system's dark ones whatever the page's colors, so their text can't take the page's: black
    /// text picked for white tiles would vanish on a dark row. Sheets keep `.dark`.
    public static var sheet: ThemeStyle { ThemeStore.shared.base }

    /// The controls locked: the top bar's padlock and the Lock tile fill with it, and a tile just added is outlined in
    /// it. The padlock's yellow in every look; custom colors can pick another. Its padlock and text: `lockedText`,
    /// black or white, whichever reads on it (the Lock tile in the engaged gray didn't stand out on a page grayed by
    /// the lock).
    public static var locked: Color { ThemeStore.shared.highlight }
    public static var lockedText: Color { ThemeStore.shared.highlightText }

    /// The page's color scheme, from its background: the status bar sits over the background, so a light one needs
    /// dark status text. Sheets stay dark (`sheet`).
    /// A camera's color as text on a tile (captions, the camera's letter): itself, unless custom colors put it on a
    /// tile it doesn't read on (yellow on white). Then it's mixed toward the text color until it reads at 3:1, WCAG's
    /// floor for bold text: the same hue, darker on light tiles. Red and blue already read on white.
    public static func legible(_ tint: Color) -> Color { ThemeStore.shared.legible(tint) }

    public static var pageScheme: ColorScheme {
        ThemeStore.shared.appearance.palette?.background.isLight == true ? .light : .dark
    }

    /// The top bar's and edit bar's color scheme, from their color: with custom colors they take the tile's, and the
    /// system's switches and buttons on a white bar have to be drawn for a light one (a dark switch vanished on it).
    public static var chromeScheme: ColorScheme {
        ThemeStore.shared.appearance.palette?.chrome.isLight == true ? .light : .dark
    }

    public static var background: Color { style.background }
    public static var strong: Color { style.strong }
    public static var backgroundText: Color { style.backgroundText ?? style.text }
    public static var backgroundSecondaryText: Color { style.backgroundSecondaryText ?? style.secondaryText }
    public static var chrome: Color { style.chrome }
    public static var tile: Color { style.tile }
    public static var control: Color { style.control }
    public static var controlSelected: Color { style.controlSelected }
    public static var text: Color { style.text }
    public static var secondaryText: Color { style.secondaryText }
    public static var timecode: Color { style.timecode }
    public static var recording: Color { style.recording }
    public static var needle: Color { style.needle }
    /// Fill for a ToggleTile (or any whole-tile boolean) when its setting is engaged / on: distinct from `recording`
    /// red, from every camera color, and from `timecode`.
    public static var engaged: Color { style.engaged }

    public static var gap: CGFloat { style.gap }
    public static var corner: CGFloat { style.corner }
    public static var border: CGFloat { style.border }

    // Tile anatomy, shared by every tile so captions, values and chevrons line up.

    /// Inset from a tile's edge to its content. The same horizontal inset everywhere, so captions and values
    /// line up down a column.
    public static let inset: CGFloat = 10
    /// Vertical inset: one value for every tile, so captions line up across a row of tiles of different heights.
    public static let insetV: CGFloat = 7
    /// A control's content while the controls are locked: about the gray of a value the camera won't
    /// change right now (`secondaryText` against `text`), so a locked page reads as locked and every value still reads.
    /// Brighter than a control the camera hasn't got (0.28), which a lock mustn't look like.
    public static let lockedOpacity: Double = 0.55
    /// Captions ("ISO", "CODEC", "TEMP"): one style in every tile.
    public static var caption: Font { style.captionFont }
    public static var captionTracking: CGFloat { style.captionTracking }
    /// Room for a caption and, beside it, a readout (f-number, Kelvin) without the readout crowding the tile's top edge.
    public static let captionHeight: CGFloat = 14
    public static let captionGap: CGFloat = 3
    /// A small control's height (a header switch, a chip, a step button): a tile shorter than this drops it.
    public static let smallControl: CGFloat = 20
    /// Readouts beside a caption (slider values, the f-number, Playback's clip count), and small information on a
    /// picture or under it (live view's frame rate, "Fetching first frame…").
    public static var readout: Font { mono(12, weight: .semibold) }
    /// Below this a tile puts caption and value on one line.
    /// The one-line value size, and the smallest a value gets in two rows: a tile with less room goes to one line
    /// rather than squeeze its value (it drew at 9 pt in a 45 pt iPhone row).
    public static let oneLineValue: CGFloat = 15
    /// Below this height a captioned tile is one line: two rows need the caption row and a 15 pt line (18 pt tall).
    public static let oneLineBelow: CGFloat = 2 * insetV + captionHeight + captionGap + 18
    /// The largest a text value gets (codec, bitrate, resolution, LUT, clip): the same in every text tile. Numbers
    /// (ISO, frame rate, shutter, white balance) are short and go larger.
    public static let textValueMax: CGFloat = 22

    /// A tile's main value: as large as `height` allows, between the one-line size and `maxSize`.
    public static func valueSize(_ height: CGFloat, max maxSize: CGFloat) -> CGFloat {
        min(maxSize, Swift.max(oneLineValue, height * 0.8))
    }

    /// The value size for a captioned tile: the one-line size on one line, `valueSize` otherwise.
    public static func valueSize(oneLine: Bool, height: CGFloat, max maxSize: CGFloat) -> CGFloat {
        oneLine ? oneLineValue : valueSize(height, max: maxSize)
    }

    /// Type size for the identity readouts (timecode, battery and card, latency), so tiles of one size in the
    /// identity strip read at one size. The width term fits a timecode: 11 monospaced characters (~7em) and its dot.
    public static func identitySize(_ size: CGSize) -> CGFloat {
        Swift.max(10, min(32, size.height * 0.45, (size.width - 2 * inset - 14) / 7))
    }

    /// Cap height of the look's value font, for centering text by its capitals and digits.
    public static func capHeight(_ size: CGFloat, weight: Font.Weight) -> CGFloat {
        let mono = style.valueDesign == .monospaced
        #if canImport(UIKit)
        let w: UIFont.Weight = weight == .heavy ? .heavy : weight == .bold ? .bold : .semibold
        return (mono ? UIFont.monospacedSystemFont(ofSize: size, weight: w) : UIFont.systemFont(ofSize: size, weight: w)).capHeight
        #elseif canImport(AppKit)
        let w: NSFont.Weight = weight == .heavy ? .heavy : weight == .bold ? .bold : .semibold
        return (mono ? NSFont.monospacedSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)).capHeight
        #else
        return size * 0.7
        #endif
    }

    /// The value and readout font: the look's design (SF Mono in Outline, SF Pro with steady digits in Ink) at
    /// `weight`, taken down the look's `valueLighter` steps.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if style.valueDesign == .monospaced && style.valueLighter == 0 { return .system(size: size, weight: weight, design: .monospaced) }
        let ladder: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let index = ladder.firstIndex(of: weight) ?? 5
        return Font.system(size: size, weight: ladder[max(0, index - style.valueLighter)], design: style.valueDesign)
            .monospacedDigit()
    }

    // MARK: Type in tiles
    // Every piece of text in a tile is one of these, with `caption` and `readout` above; tile code uses nothing else.
    // `TileTypographyTests` fails on `Theme.mono(` or `.system(size:` in a tile file, so a tile can't make up a style.

    /// A tile's main value (ISO, codec, white balance, the shutter dial's angle, a Naming part): bold, at `valueSize`.
    public static func value(_ size: CGFloat) -> Font { mono(size, weight: .bold) }
    /// A value's second part, smaller and muted, on its baseline ("→ 24" after the off-speed rate, "4:2:2 10bit").
    public static func detail(forValue size: CGFloat) -> Font { mono(Swift.max(10, (size * 0.6).rounded()), weight: .semibold) }
    /// The identity strip's readouts (timecode, battery, card, latency) and the model beside the camera's letter.
    public static func identity(_ size: CGFloat) -> Font { mono(size, weight: .semibold) }
    /// A camera's letter: in the identity strip, on camera chips.
    public static func letter(_ size: CGFloat) -> Font { mono(size, weight: .heavy) }
    /// REC and STOP, sized to the button.
    public static func hero(_ size: CGFloat) -> Font { mono(size, weight: .heavy) }
    /// A tile that is one button (False Color, LUT, Monitoring Options, Web GUI), and a button's title: 12 pt short.
    public static func buttonLabel(short: Bool = false) -> Font { mono(short ? 12 : 15, weight: .semibold) }
    /// A full-size segmented control's options (Fixed | Var, Live | Review, AF-C | MF); a small one uses `caption`.
    public static let segment = Font.system(size: 12, weight: .semibold)
    /// The chevrons, ⌄ (a menu) and › (a window): one size everywhere.
    public static let chevron = Font.system(size: 10, weight: .bold)
    /// An SF Symbol in a control (transport buttons, ±, the step arrows). Icons are sized by their control, not the
    /// type scale; this is the one way to size one.
    public static func symbol(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight) }

    // MARK: Type and metrics under Text Size
    // A tile's `tileScale` (Dynamic, `TextZoom`; 1 with Standardized) multiplies its type, insets, controls and the
    // thresholds it compares its size with, so a zoomed tile is drawn at real font sizes, sharp, with the layout it has at
    // its size over the scale. Text Size's slider (`textBump`) multiplies the small type on top: captions, readouts,
    // switches' and buttons' labels, chevrons and a one-line value, with the caption row that holds a caption. At 1 and
    // 100 % each of these is exactly its standard token.

    /// Text Size's slider (`AppearanceSettings.textScale`, 1 to 1.5): every tile's small type that many times the
    /// standard. Values sized to their room, insets and controls stay as they are, so a big value doesn't shrink for it.
    public static var textBump: CGFloat { CGFloat(ThemeStore.shared.appearance.textScale) }
    /// The caption row's height at the slider's size, and how much taller that is than the standard (0 at 100 %): a
    /// height that holds a caption row grows by it.
    public static var captionRow: CGFloat { captionHeight * textBump }
    public static var captionRowGrowth: CGFloat { captionRow - captionHeight }
    public static func captionRow(_ s: CGFloat) -> CGFloat { captionRow * s }
    /// A caption's line at the slider's size: a line shorter than this keeps the standard type (`shortLine`).
    public static func captionLine(_ s: CGFloat) -> CGFloat { 13 * s * textBump }
    /// The scale a tile's small type is drawn at: `s`, or on a line too short for the slider's bigger type, `s` over
    /// the slider's, which gives the standard type.
    public static func textScale(_ s: CGFloat, shortLine: Bool) -> CGFloat { shortLine ? s / textBump : s }

    public static func caption(_ s: CGFloat) -> Font {
        let t = s * textBump
        return t == 1 ? caption : .system(size: 10 * t, weight: style.captionWeight)
    }
    public static func captionTracking(_ s: CGFloat) -> CGFloat { captionTracking * s * textBump }
    public static func readout(_ s: CGFloat) -> Font { let t = s * textBump; return t == 1 ? readout : mono(12 * t, weight: .semibold) }
    public static func buttonLabel(short: Bool = false, scale s: CGFloat) -> Font {
        mono((short ? 12 : 15) * s * textBump, weight: .semibold)
    }
    public static func segment(_ s: CGFloat) -> Font { let t = s * textBump; return t == 1 ? segment : .system(size: 12 * t, weight: .semibold) }
    public static func chevron(_ s: CGFloat) -> Font { let t = s * textBump; return t == 1 ? chevron : .system(size: 10 * t, weight: .bold) }
    /// The lock where a value set on the camera has no chevron (`ValueLine.setOnCamera`): smaller than the chevron's
    /// size, as a lock stands taller than ⌄ and a 10 pt one cut a one-line value off in a 9 pt tile.
    public static func lockGlyph(_ s: CGFloat) -> Font { .system(size: 7 * s * textBump, weight: .bold) }
    /// `valueSize(_:max:)` with the floor and the cap times `s`.
    public static func valueSize(_ height: CGFloat, max maxSize: CGFloat, scale s: CGFloat) -> CGFloat {
        min(maxSize * s, Swift.max(oneLineValue * s, height * 0.8))
    }
    /// `valueSize(oneLine:height:max:)` with the one-line size, the floor and the cap times `s`, and the one-line size
    /// times the slider's too where the line has the height for it (a phone on its side draws 12 pt lines).
    public static func valueSize(oneLine: Bool, height: CGFloat, max maxSize: CGFloat, scale s: CGFloat) -> CGFloat {
        oneLine ? min(oneLineValue * s * textBump, Swift.max(oneLineValue * s, height * 0.8)) : valueSize(height, max: maxSize, scale: s)
    }
    /// `detail(forValue:)` with its floor times `s` and the slider's.
    public static func detail(forValue size: CGFloat, scale s: CGFloat) -> Font {
        let t = s * textBump
        return t == 1 ? detail(forValue: size) : mono(Swift.max(10 * t, size * 0.6), weight: .semibold)
    }
}

private struct TileScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct ShortLineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Dynamic Text Size's scale for the tile being drawn (`TextZoom`): its type, insets, controls and thresholds are this
    /// many times the standard. 1 with Standardized, and outside tiles.
    public var tileScale: CGFloat {
        get { self[TileScaleKey.self] }
        set { self[TileScaleKey.self] = newValue }
    }

    /// A one-line tile (or row) shorter than a caption at Text Size's bigger type (`Theme.captionLine`): its captions,
    /// labels and chevrons keep the standard size rather than run out of the tile (a phone on its side, 10–14 pt rows).
    public var shortLine: Bool {
        get { self[ShortLineKey.self] }
        set { self[ShortLineKey.self] = newValue }
    }
}

extension CameraSlot {
    /// The camera's color as the page draws it: the one picked for it (`customColor`), else its slot color.
    var tint: Color { customColor.map(Color.init) ?? color.color }
    /// Text that reads on a badge filled with `tint`.
    var badgeText: Color { customColor.map { $0.isLight ? Color.black : .white } ?? color.badgeText }
}

extension CameraProfileRecord {
    /// The profile's color: the one picked for it, else its slot color.
    var tint: Color { customColor.map(Color.init) ?? color.color }
}

extension SlotColor {
    var color: Color {
        switch self {
        case .red: Color(red: 0.93, green: 0.28, blue: 0.26)
        case .blue: Color(red: 0.17, green: 0.50, blue: 0.98)
        case .yellow: Color(red: 0.98, green: 0.80, blue: 0.10)
        case .green: Color(red: 0.24, green: 0.80, blue: 0.34)
        case .orange: Color(red: 0.98, green: 0.56, blue: 0.16)
        case .purple: Color(red: 0.66, green: 0.42, blue: 0.95)
        case .teal: Color(red: 0.22, green: 0.78, blue: 0.80)
        case .pink: Color(red: 0.98, green: 0.38, blue: 0.62)
        }
    }

    /// Text color that stays readable on a badge filled with this color.
    var badgeText: Color { self == .yellow ? .black : .white }
}

enum Format {
    static func angle(_ degrees: Double) -> String {
        degrees.rounded() == degrees ? "\(Int(degrees))°" : String(format: "%.1f°", degrees)
    }

    /// Tint with the camera's own letters: G (green, negative) or M (magenta, positive), in its own steps; the FX3
    /// moves in quarters, so M0.25 mustn't read as 0.
    static func tint(_ value: Double) -> String {
        let quarters = (value * 4).rounded() / 4
        guard quarters != 0 else { return "0" }
        return (quarters < 0 ? "G" : "M") + String(format: "%g", abs(quarters))
    }

    /// A frequency to the hundredth: "240.00 Hz" (an FX6's ECS).
    static func hertz(_ value: Double) -> String { String(format: "%.2f Hz", value) }

    /// Lens-style f-number: one decimal below 10 (f/2.8, f/4.0), whole numbers above (f/11, f/16).
    static func fNumber(_ value: Double) -> String {
        value >= 10 ? "f/\(Int(value.rounded()))" : String(format: "f/%.1f", value)
    }
}

extension VerticalAlignment {
    private enum CapCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// The middle of a line's capitals. Line boxes include room for descenders, so text centered by its box sits high;
    /// the identity readouts center on this instead.
    static let capCenter = VerticalAlignment(CapCenter.self)
}

extension Alignment {
    static let centerCapCenter = Alignment(horizontal: .center, vertical: .capCenter)
}

extension View {
    /// Puts this text's `.capCenter` guide in the middle of its capitals at `size` and `weight`.
    func capCentered(_ size: CGFloat, weight: Font.Weight) -> some View {
        alignmentGuide(.capCenter) { d in d[.firstTextBaseline] - Theme.capHeight(size, weight: weight) / 2 }
    }
}

