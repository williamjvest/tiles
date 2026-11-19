import XCTest

/// The ND tile's − + step buttons are an option set in edit mode, off unless switched: the chip
/// under the tile's name switches them, and the page shows the change once editing's done. On a working demo VENICE 2, held in memory
/// (`-CCDebugDemoBodies`), so nothing saved is touched.
@MainActor
final class NDStepTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testTheStepChipSwitchesTheNDTilesButtons() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", "venice2"]
        app.launch()
        let edit = app.buttons["Edit Tiles"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "no Edit Tiles")
        // Off unless switched on in edit mode.
        XCTAssertFalse(app.buttons["ndStepDown"].waitForExistence(timeout: 2), "the ND tile shows − by default")

        edit.tap()
        let chip = app.buttons["stepChip"].firstMatch  // one per ND tile
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no Step chip on the ND tile in edit mode")
        XCTAssertEqual(chip.value as? String, "Off")
        chip.tap()
        XCTAssertEqual(chip.value as? String, "On", "the Step chip didn't switch")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["ndStepDown"].waitForExistence(timeout: 5), "the ND tile's − didn't appear with Step on")

        edit.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertEqual(chip.value as? String, "Off")
        app.buttons["Done"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["ndStepDown"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the ND tile still shows − with Step off")
    }
}
