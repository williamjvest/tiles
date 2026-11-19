import Testing
import CameraCore
@testable import DashboardUI

/// Settings → Appearance's tile outlines: a line round each tile in its camera's color, on any look.
@Suite("Tile outlines")
struct OutlineTests {
    @Test("Ink draws none until they're switched on, then at the width picked")
    func inkWithOutlines() {
        #expect(!ThemeStyle.ink.drawsOutline)
        #expect(!ThemeStyle.ink.applying(AppearanceSettings()).drawsOutline)
        let on = ThemeStyle.ink.applying(AppearanceSettings(outlines: true, outlineWidth: 3))
        #expect(on.drawsOutline)
        #expect(on.border == 3)
    }

    @Test("They go with custom colors too, and the Outline look keeps its own")
    func withCustomColoursAndOutlineLook() {
        let custom = ThemeStyle.ink.applying(AppearanceSettings(customColors: true, outlines: true, outlineWidth: 2))
        #expect(custom.drawsOutline)
        #expect(custom.border == 2)
        #expect(ThemeStyle.outline.drawsOutline)
        #expect(ThemeStyle.outline.applying(AppearanceSettings()).border == 1.5)
    }

    @Test("Settings names them in its summary")
    func summary() {
        #expect(appearanceSummary(AppearanceSettings(outlines: true)) == "Outlines")
        #expect(AppearanceView.points(1.5) == "1.5 pt")
        #expect(AppearanceView.points(2) == "2 pt")
    }
}
