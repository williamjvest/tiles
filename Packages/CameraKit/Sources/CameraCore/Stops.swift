import Foundation

/// Exposure in stops, as lenses and filters are marked, for the backends whose cameras speak stops.
public enum Stops {
    /// The f-numbers a lens barrel marks, a third of a stop apart from f/1 (AV 0) to f/32: the AV of each is its
    /// index ÷ 3. f-numbers are geometric, so they aren't evenly spaced.
    public static let fNumbers: [Double] = [1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0,
                                            5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32]

    /// An ND filter as its ND number, the optical density: 0.3 a stop, so 2, 4 and 6 stops read 0.6, 1.2 and 1.8, as
    /// filters are marked on set. No filter is Clear.
    public static func ndLabel(_ stops: Double) -> String {
        stops == 0 ? "Clear" : String(format: "%g", (stops * 0.3 * 100).rounded() / 100)
    }

    /// The stops an `ndLabel` came from, to two places (0.6 / 0.3 is 2.0000000000000004).
    public static func ndStops(_ label: String) -> Double? {
        if label == "Clear" { return 0 }
        guard let density = Double(label) else { return nil }
        return (density / 0.3 * 100).rounded() / 100
    }
}
