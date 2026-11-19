import Foundation
import Testing

/// Every text in a tile takes one of `Theme`'s type roles (docs/design-style-guide.md § Type scale). A tile that sizes
/// its own text drifts from the rest: unchecked, the tiles accumulated 17 styles of their own (a 9 pt live chip, an
/// 11 pt Color Bars toggle, a 10 pt clip count).
@Suite("Tile typography")
struct TileTypographyTests {
    /// The files that draw tiles. Sheets inside them use the system's text styles (`.body`), which this allows.
    static let tileFiles = ["Tiles/IdentityTiles.swift", "Tiles/ExposureTiles.swift", "Tiles/RecordingTiles.swift",
                            "Tiles/MonitoringTiles.swift", "Tiles/LiveViewTiles.swift", "Tiles/PlaybackTile.swift",
                            "AudioTiles.swift", "Components.swift", "GridPageView.swift", "HaLowTile.swift"]
    /// A font made up on the spot instead of a role.
    static let madeUp = ["Theme.mono(", ".system(size:", "Font.system("]

    @Test("Tile code takes its fonts from Theme's roles", arguments: tileFiles)
    func rolesOnly(file: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DashboardUI/\(file)")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var offenders: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if !code.hasPrefix("//"), Self.madeUp.contains(where: { code.contains($0) }) { offenders.append("\(index + 1): \(code)") }
        }
        #expect(offenders.isEmpty, "\(file): \(offenders.joined(separator: "; "))")
    }

    /// A title wraps where its tile is too narrow, not where someone typed a line break: "Frame\nGuides" sat on two
    /// lines beside a one-line "False Color" in a tile of the same width.
    @Test("Tile titles carry no line breaks", arguments: tileFiles)
    func noHardBreaks(file: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DashboardUI/\(file)")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let broken = try Regex(#""[A-Za-z ]+\\n[A-Za-z ]+""#)
        let offenders = lines.enumerated().filter { line in
            let code = line.element.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && code.contains("title") && code.contains(broken)
        }.map { "\($0.offset + 1)" }
        #expect(offenders.isEmpty, "\(file): lines \(offenders.joined(separator: ", "))")
    }
}
