import XCTest
@testable import SonySavona

/// What the real VENICE 2 (FW V4.00, savona-2.9.4) shows over HaLow: several messages per WebSocket
/// frame, some split across frames; menu values that are numbers with names in the page's own table; S&Q rates as a
/// numerator over a denominator.
final class VeniceSessionTests: XCTestCase {
    func testOneFrameCarriesSeveralMessagesAndASplitTail() {
        let a = MessagePack.encode(.array([.int(2), .string("Notify.Property.Status.Changed"),
                                           .array([.map(["Button.Play": .string("Unlocked")])])]))
        let b = MessagePack.encode(.array([.int(1), .int(7), .null, .map(["x": .int(1)])]))
        let c = MessagePack.encode(.array([.int(2), .string("Notify.Property.Value.Changed"),
                                           .array([.map(["Camera.NDFilter.Value": .map(["cam": .int(4)])])])]))
        let first = MessagePack.decodeAll(a + b + c.prefix(5))
        XCTAssertEqual(first.values.count, 2)
        XCTAssertEqual(first.rest, Data(c.prefix(5)))
        let second = MessagePack.decodeAll(first.rest + c.dropFirst(5))
        XCTAssertEqual(second.values.count, 1)
        XCTAssertEqual(second.values.first?[1]?.string, "Notify.Property.Value.Changed")
        XCTAssertTrue(second.rest.isEmpty)
    }

    func testPaddedStringsAndNestedSingleValues() throws {
        let clip = try MessagePack.decode(MessagePack.encode(.string("B020C004\u{0}")))
        XCTAssertEqual(clip.string, "B020C004")
        XCTAssertEqual(MPValue.map(["main": .string("B020C005")]).unwrapped.string, "B020C005")
        XCTAssertEqual(MPValue.map(["sdi1": .string("Log(Legal)")]).unwrapped.string, "Log(Legal)")
        XCTAssertEqual(MPValue.string("1").bool, true)
        XCTAssertEqual(MPValue.string("0").bool, false)
    }

    func testMenuValuesHaveTheCamerasNames() {
        XCTAssertEqual(VeniceMenu.label(VeniceMenu.imagerModes, value: .string("17")), "8.6K 3:2")
        XCTAssertEqual(VeniceMenu.value(VeniceMenu.imagerModes, label: "5.8K 6:5"), "25")
        XCTAssertEqual(VeniceMenu.label(VeniceMenu.recordingFormats, value: .string("3")), "X-OCN LT")
        XCTAssertEqual(VeniceMenu.value(VeniceMenu.projectRates, label: "24"), "6")
        // The capability list is item indices: 13–23 are the 8.6K sensor's modes.
        let allowed = (13...23).map { MPValue.string(String($0)) }
        XCTAssertEqual(VeniceMenu.labels(VeniceMenu.imagerModes, allowed: allowed).first, "8.6K 3:2")
        XCTAssertEqual(VeniceMenu.labels(VeniceMenu.imagerModes, allowed: allowed).count, 11)
        XCTAssertEqual(VeniceMenu.labels(VeniceMenu.projectRates, allowed: ["0", "1", "2", "3"].map(MPValue.string)),
                       ["23.98", "24", "25", "29.97"])
    }

    func testSlowAndQuickRatesAsThePageWritesThem() {
        XCTAssertEqual(VeniceCameraBackend.sqRateProps("Camera.SlowAndQuickMotion.FrameRate", 24)["Camera.SlowAndQuickMotion.FrameRate.Denominator"], .int(1))
        let thirds = VeniceCameraBackend.sqRateProps("Camera.SlowAndQuickMotion.FrameRate", 33.33)
        XCTAssertEqual(thirds["Camera.SlowAndQuickMotion.FrameRate"], .int(100))
        XCTAssertEqual(thirds["Camera.SlowAndQuickMotion.FrameRate.Denominator"], .int(3))
    }

    func testShutterSpeedsLUTSlotsAndWhiteBalanceLabels() {
        // ShutterConverter.js: "1/24.00" reads as 1/24; "1/50" goes back as "1/50.00".
        XCTAssertEqual(VeniceCameraBackend.speedLabel("1/24.00"), "1/24")
        XCTAssertEqual(VeniceCameraBackend.speedLabel("1/47.95"), "1/47.95")
        XCTAssertEqual(VeniceCameraBackend.speedValue("1/50"), "1/50.00")
        XCTAssertEqual(VeniceCameraBackend.speedValue("1/47.9"), "1/47.90")
        XCTAssertEqual(VeniceCameraBackend.speedValue("1/47.95"), "1/47.95")
        // LUTConverter.js: one map per output group, {key: name}; each output's own capability list.
        XCTAssertEqual(VeniceCameraBackend.slot("Output.Video.ViewFinder.LUT.Value#monitor")?.key, "monitor")
        XCTAssertNil(VeniceCameraBackend.slot("Camera.NDFilter.Value"))
        XCTAssertEqual(VeniceCameraBackend.capabilityName("Output.Video.SDI.LUT.Value#sdi3"), "Output.Video.SDI.LUT.Value.SDI3")
        XCTAssertEqual(VeniceCameraBackend.capabilityName("Output.Video.ViewFinder.LUT.Value#monitor"),
                       "Output.Video.ViewFinder.LUT.Value.Monitor")
        XCTAssertEqual(VeniceCameraBackend.wbLabel(kelvin: 5600, tint: 0), "5600K")
        XCTAssertEqual(VeniceCameraBackend.wbLabel(kelvin: 4200, tint: 8), "4200K +8")
    }
}
