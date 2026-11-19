import Testing
import Foundation
@testable import SonyPTP

/// Tint direction. Sony's 0xD210 puts green above the 0xC0 center (min 0x9C = M9.00, max 0xE4 = G9.00);
/// the app's convention is negative = green, positive = magenta. Read the other way, the slider runs backwards.
@Suite("White balance tint direction")
struct WhiteBalanceTests {
    @Test("Encoding: magenta is below the centre, green above")
    func encodesSonysDirection() {
        #expect(encodeTintGM(9) == Data([0x9C]))      // M9.00
        #expect(encodeTintGM(-9) == Data([0xE4]))     // G9.00
        #expect(encodeTintGM(0) == Data([0xC0]))
        #expect(encodeTintGM(0.25) == Data([0xBF]))   // M0.25
        #expect(encodeTintGM(-1.5) == Data([0xC6]))   // G1.50
    }
}

