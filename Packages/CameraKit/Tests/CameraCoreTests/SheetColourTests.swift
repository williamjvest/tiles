import Foundation
import Testing

/// Sheets and forms keep the standard look whatever Settings → Appearance gives the page (docs/design-style-guide.md
/// § Appearance): their rows are the system's dark ones, so their text takes `Theme.sheet`'s colors. A page token there
/// follows the custom colors, and with the daylight set that's black text on a dark row.
@Suite("Sheet colours")
struct SheetColourTests {
    /// The files that are only sheets and forms. The tiles (Tiles/), DashboardView.swift and HaLowTile.swift mix sheets
    /// with tiles; AppearanceView.swift draws its preview in the page's colors on purpose.
    static let sheetFiles = ["Settings.swift", "MeshDevicesSection.swift", "BluetoothCamerasSection.swift",
                             "ControlAPISettings.swift", "LUTImportView.swift", "CameraMenuView.swift",
                             "ColourPicking.swift", "AudioView.swift"]

    @Test("Sheet code takes Theme.sheet's colors, not the page's", arguments: sheetFiles)
    func sheetColours(file: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DashboardUI/\(file)")
        let page = try Regex(#"Theme\.(style\.)?(text|secondaryText|timecode|needle|background|chrome|tile|control|controlSelected|engaged|accent|accentText|strong|backgroundText|backgroundSecondaryText)\b"#)
        let offenders = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated().filter {
            let code = $0.element.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && code.contains(page)
        }.map { "\($0.offset + 1)" }
        #expect(offenders.isEmpty, "\(file): lines \(offenders.joined(separator: ", ")) use a page colour; use Theme.sheet.…")
    }
}
