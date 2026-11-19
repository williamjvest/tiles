import XCTest

/// Dynamic Text Size (Settings → Appearance) draws each tile's type, insets and controls bigger, at
/// real font sizes (`tileScale`). Taps, menus and switches have to land on the bigger controls, and the setting has to
/// apply as it's switched. On a working demo VENICE 2 held in memory, on a big iPad, where tiles grow most.
/// Screenshots of both sizes go to $TILES_UITEST_SHOTS when it's set, to check the bigger text is sharp. iPad only: a
/// phone's tiles are already at their smallest across, and stay at 1.
@MainActor
final class DynamicTextTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a phone's tiles stay at Standardized's size")
    }

    func testBiggerTilesStillTakeTaps() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", "venice2", "-CCDebugTextSize", "dynamic"]
        app.launch()
        let wb = app.staticTexts["5500K"].firstMatch
        XCTAssertTrue(wb.waitForExistence(timeout: 15), "no white balance tile")
        shoot("dynamic")

        // A value's picker: the menu opens from the value, and a pick lands.
        wb.tap()
        let option = app.buttons["4300K"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "the white balance menu didn't open")
        XCTAssertTrue(option.tap(until: { app.staticTexts["4300K"].firstMatch.exists }), "the pick didn't land")

        // A switch, full size or small: Speed shows the shutter as a speed, Angle as an angle.
        let speed = app.buttons.matching(NSPredicate(format: "label IN %@", ["Speed", "SPD"])).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "no Angle | Speed switch")
        speed.tap()
        let asSpeed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1/'")).firstMatch
        XCTAssertTrue(asSpeed.waitForExistence(timeout: 5), "Speed didn't take the tap")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Angle", "ANG"])).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["180°"].firstMatch.waitForExistence(timeout: 5), "Angle didn't take the tap")

        // A toggle tile.
        let bars = app.buttons["Color Bars"].firstMatch
        XCTAssertTrue(bars.waitForExistence(timeout: 5), "no Color Bars tile")
        XCTAssertEqual(bars.value as? String, "Off")
        bars.tap()
        XCTAssertEqual(bars.value as? String, "On", "the toggle tile didn't take the tap")
        bars.tap()
        XCTAssertEqual(bars.value as? String, "Off")
    }

    /// Switched in Settings, the page changes as soon as Settings closes, and back.
    func testTextSizeAppliesAsItsSwitched() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", "venice2"]
        app.launch()
        let temp = app.staticTexts["TEMP"].firstMatch
        XCTAssertTrue(temp.waitForExistence(timeout: 15), "no White Balance sliders tile")
        shoot("standardized")
        let standard = temp.frame.height

        setTextSize(app, "Dynamic")
        XCTAssertGreaterThan(temp.frame.height, standard * 1.1, "Dynamic didn't draw the tile's caption bigger")
        setTextSize(app, "Standardized")
        XCTAssertEqual(temp.frame.height, standard, accuracy: 0.5, "Standardized didn't put the caption back")
    }

    private func setTextSize(_ app: XCUIApplication, _ size: String) {
        app.buttons["Settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Appearance row in Settings")
        row.tap()
        let segment = app.segmentedControls["textSize"].buttons[size]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "no Text Size switch in Appearance")
        // Appearance is still sliding in: a tap then can be dropped (`tap(until:)`).
        XCTAssertTrue(segment.tap(until: { segment.isSelected }), "\(size) isn't selected")
        app.navigationBars.buttons.element(boundBy: 0).tap()  // back to Settings
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForHittable(timeout: 5), "Settings didn't close")
    }

    private func shoot(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        guard let dir = ProcessInfo.processInfo.environment["TILES_UITEST_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/text-\(name).png"))
    }
}
