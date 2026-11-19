import Testing
@testable import DashboardUI

/// The Latency tile's color and the top bar's bars from a camera's round trip: Wi-Fi's scale, and HaLow's, whose own
/// floor is higher (right beside the camera over HaLow the bars read medium or low, not high).
@Suite("Latency grade")
struct LatencyGradeTests {
    @Test("Wi-Fi: 4 bars under 50 ms, 3 under 80, 2 (yellow) under 200, then 1 (red)")
    func wifi() {
        #expect([10, 49, 50, 79, 80, 199, 200, 900].map { LatencyGrade.grade($0, overHaLow: false).bars }
                == [1, 1, 0.75, 0.75, 0.5, 0.5, 0.25, 0.25])
    }

    @Test("HaLow: 4 bars under 150 ms, 3 under 300, 2 under 600, then 1")
    func haLow() {
        #expect([30, 149, 150, 299, 300, 599, 600, 2000].map { LatencyGrade.grade($0, overHaLow: true).bars }
                == [1, 1, 0.75, 0.75, 0.5, 0.5, 0.25, 0.25])
    }

    @Test("A link that read medium or low on Wi-Fi's scale reads green over HaLow")
    func besideTheCamera() {
        for ms in [90, 150, 220, 280] {
            #expect(LatencyGrade.grade(ms, overHaLow: false).bars <= 0.5, "\(ms) ms on Wi-Fi's scale")
            #expect(LatencyGrade.grade(ms, overHaLow: true).bars >= 0.75, "\(ms) ms over HaLow")
        }
    }
}
