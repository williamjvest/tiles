import Foundation

/// LUTs that ship with the app.
public enum BundledLUT {
    /// The name it's loaded under. "False Color" in it is what makes the LUT tile offer its False Color switch.
    public static let falseColorName = "TW False Color"

    /// Tiles' false color for S-Log3 / S-Gamut3.Cine, 33-point (scripts/make-false-color-lut.py): the LUTCalc
    /// bands, computed by the app's own script so no third-party file ships.
    public static var falseColor: Data? {
        Bundle.module.url(forResource: "TW False Color SLog3", withExtension: "cube").flatMap { try? Data(contentsOf: $0) }
    }
}
