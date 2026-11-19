import Foundation
import Testing
@testable import CameraCore

/// Settings → Appearance (`AppearanceSettings`): what's saved, and the colors made from the three picked.
@Suite("Appearance")
struct AppearanceTests {
    typealias RGB = AppearanceSettings.RGB

    @Test("A saved appearance comes back as it was")
    func roundTrip() throws {
        let saved = AppearanceSettings(customColors: true, tile: RGB(red: 1, green: 0.9, blue: 0.8),
                                       background: .black, text: RGB(white: 0.1), corner: 4)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: data) == saved)
    }

    @Test("Tile outlines: off unless switched on, saved with their width, the width kept in its range")
    func outlines() throws {
        #expect(AppearanceSettings.standard.outlines == false)
        #expect(AppearanceSettings.standard.outlineWidth == 1.5)
        let on = AppearanceSettings(outlines: true, outlineWidth: 2.5)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(on)) == on)
        // Saved by a build from before outlines: off, at the standard width.
        let older = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"corner":4}"#.utf8))
        #expect(older.outlines == false)
        #expect(older.outlineWidth == 1.5)
        var a = AppearanceSettings()
        a.outlineWidth = 9
        #expect(a.outlineWidth == 4)
        a.outlineWidth = 0.2
        #expect(a.outlineWidth == 1)
        a.outlineWidth = 2.3
        #expect(a.outlineWidth == 2.5)
        #expect(AppearanceSettings(outlineWidth: .nan).outlineWidth == 1.5)
    }

    @Test("Text Size is saved, and one this build doesn't know reads as Standardized")
    func textSize() throws {
        let dynamic = AppearanceSettings(corner: 4, textSize: .dynamic)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(dynamic)) == dynamic)
        #expect(AppearanceSettings.standard.textSize == .standardized)
        let later = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"corner":4,"textSize":"huge"}"#.utf8))
        #expect(later.textSize == .standardized)
        #expect(later.corner == 4)
    }

    @Test("Text Size's slider is kept in tenths from 100 to 150 %, and a setup saved before it reads as 100 %")
    func textScale() throws {
        #expect(AppearanceSettings(textScale: 1.26).textScale == 1.3)
        #expect(AppearanceSettings(textScale: 3).textScale == 1.5)
        #expect(AppearanceSettings(textScale: 0.5).textScale == 1)
        #expect(AppearanceSettings(textScale: .nan).textScale == 1)
        var set = AppearanceSettings.standard
        set.textScale = 1.44
        #expect(set.textScale == 1.4)
        #expect(AppearanceSettings.standard.textScale == 1)
        let saved = AppearanceSettings(textScale: 1.2)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(saved)) == saved)
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"corner":4}"#.utf8)).textScale == 1)
    }

    @Test("Tiles' color picker: hex in and out, and hue, saturation and brightness")
    func pickerColours() throws {
        #expect(RGB(hex: "FFCC00")?.hex == "FFCC00")
        #expect(RGB(hex: "#ffcc00")?.hex == "FFCC00")
        #expect(RGB(hex: "FC0")?.hex == "FFCC00")
        #expect(RGB(hex: " 000000 ")?.hex == "000000")
        for bad in ["", "#", "12345", "1234567", "GGGGGG", "+12345", "-12345", "FF CC0"] {
            #expect(RGB(hex: bad) == nil, "\(bad) read as a colour")
        }
        for hex in ["FF0000", "00FF00", "0000FF", "FFCC00", "7F3FBF", "FFFFFF", "000000", "808080"] {
            let colour = try #require(RGB(hex: hex))
            let (h, s, b) = colour.hsb
            #expect(RGB(hue: h, saturation: s, brightness: b).matches(colour), "\(hex) didn't come back through HSB")
        }
        #expect(RGB(hue: 1, saturation: 1, brightness: 1).hex == "FF0000")  // 1 is red again
        #expect(RGB(hex: "808080")!.hsb.saturation == 0)
        #expect(RGB(red: 0.5, green: 0.5, blue: 0.5).matches(RGB(red: 0.5 + 0.4 / 255, green: 0.5, blue: 0.5)))
        #expect(!RGB(red: 0.5, green: 0.5, blue: 0.5).matches(RGB(red: 0.5 + 0.6 / 255, green: 0.5, blue: 0.5)))
    }

    /// A field a later build adds is missing from what an earlier one saved: it takes its default, and the rest stand.
    @Test("Missing fields take their defaults")
    func missingFields() throws {
        #expect(try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8)) == .standard)
        let cornerOnly = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"corner":0}"#.utf8))
        #expect(cornerOnly.corner == 0)
        #expect(cornerOnly.customColors == false)
    }

    @Test("Standard is the look untouched; custom colors start on white tiles, black text, black")
    func defaults() {
        #expect(AppearanceSettings.standard.palette == nil)
        #expect(AppearanceSettings.standard.corner == nil)
        var custom = AppearanceSettings.standard
        custom.customColors = true
        #expect(custom.tile == .white)
        #expect(custom.background == .black)
        #expect(custom.text == .black)
    }

    @Test("Corners stay within the slider's range")
    func cornerClamped() {
        #expect(AppearanceSettings(corner: -3).corner == 0)
        #expect(AppearanceSettings(corner: 99).corner == AppearanceSettings.corners.upperBound)
        #expect(RGB(red: 3, green: -2, blue: .nan) == RGB(red: 2, green: -1, blue: 0))
    }

    /// iOS's picker hands back Display P3, a little outside sRGB for a vivid pick: kept as picked (so the picker doesn't
    /// jump back to sRGB's nearest), while luminance and contrast count it as sRGB's edge.
    @Test("A wide-gamut pick is kept; the maths treats it as sRGB's edge")
    func wideGamut() {
        let p3Green = RGB(red: -0.14, green: 1.02, blue: -0.07)
        #expect(p3Green.red == -0.14)
        #expect(p3Green.luminance == RGB(red: 0, green: 1, blue: 0).luminance)
        #expect(p3Green.contrasting == .black)
    }

    /// The steps between tile and text are Ink's: its own three colors give back its grays.
    @Test("Ink's colors give back Ink's grays")
    func inkProportions() {
        let ink = AppearancePalette(tile: RGB(white: 0.07), background: .black, text: RGB(white: 0.96))
        func near(_ colour: RGB, _ white: Double) -> Bool { abs(colour.red - white) < 0.01 }
        #expect(near(ink.control, 0.15))
        #expect(near(ink.controlSelected, 0.30))
        #expect(near(ink.engaged, 0.30))
        #expect(near(ink.secondaryText, 0.56))
        #expect(near(ink.dialRing, 0.20))
        #expect(near(ink.dialTick, 0.50))
        #expect(near(ink.track, 0.17))
        #expect(ink.controlSelectedText == .white)
        #expect(ink.accentText == .black)
        #expect(ink.backgroundText == RGB(white: 0.96))
    }

    /// The daylight set. Everything in the bars is drawn in a tile's colors, so the bars take the tile's color: black
    /// text on a black bar would vanish. Text on the bare background turns white for the same reason.
    @Test("White tiles and black text on black stay readable everywhere")
    func daylight() {
        let p = AppearancePalette(tile: .white, background: .black, text: .black)
        #expect(p.chrome == .white)
        #expect(abs(p.text.contrast(with: p.tile) - 21) < 1e-9)
        #expect(p.secondaryText.contrast(with: p.tile) >= 4.5)
        #expect(p.text.contrast(with: p.chrome) >= 4.5)
        #expect(p.accentText.contrast(with: p.accent) >= 4.5)
        #expect(p.controlSelectedText.contrast(with: p.controlSelected) >= 4.5)
        #expect(p.text.contrast(with: p.engaged) >= 4.5)
        #expect(p.backgroundText == .white)
        #expect(p.backgroundSecondaryText.contrast(with: p.background) >= 4.5)
    }

    @Test("Contrast and luminance follow WCAG")
    func wcag() {
        #expect(abs(RGB.white.luminance - 1) < 1e-9)
        #expect(RGB.black.luminance == 0)
        #expect(abs(RGB.black.contrast(with: .white) - 21) < 1e-9)
        #expect(RGB(white: 0.3).contrasting == .white)
        #expect(RGB(white: 0.74).contrasting == .black)
    }
}
