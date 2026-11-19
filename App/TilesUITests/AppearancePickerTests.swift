import XCTest

/// Settings → Appearance's colors open Tiles' color picker from their wells, and a pick applies at once. Tiles'
/// own picker is used because Apple's system picker failed on some iPads: an empty popover, then an empty sheet.
/// Against the app's own setup; leaves custom colors off, on the daylight set.
@MainActor
final class AppearancePickerTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testEachColourOpensThePickerAndAPickApplies() throws {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "no Settings button")
        // The top bar's left end, which is bar and nothing else: the tiles' color with custom colors on.
        let bar = CGPoint(x: 6, y: settings.frame.midY)
        let pageShows = app.windows.firstMatch.frame.width >= 700  // on a phone the sheet covers the page
        settings.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Appearance row in Settings")
        row.tap()
        let toggle = app.switches["Custom Colors"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Appearance didn't open")
        setSwitch(toggle, on: true)
        let reset = app.buttons["Reset Colors"]
        if reset.isEnabled { reset.tap() }

        for name in ["Tiles", "Background", "Text", "Highlight"] {
            let colour = app.buttons["colourRow.\(name)"]
            XCTAssertTrue(colour.waitForExistence(timeout: 5), "no \(name) row")
            // Where a finger lands: the well at the row's end.
            colour.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 5), "\(name): the colour picker didn't open")
            // Drawn in the app: the grid's colors are there to tap.
            XCTAssertTrue(app.buttons["colourGrid.0.11"].exists, "\(name): the picker is empty")
            closePicker(app)
        }

        // A pick applies as it's made: the tiles go black from the grid, and the bar with them, and the hex field shows
        // it. (Mid-edit too, which only a Mac shows: `ColourPickerHexTests`.)
        app.buttons["colourRow.Tiles"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["colourGrid.0.11"].waitForExistence(timeout: 5))
        let field = app.textFields["colourPickerHex"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no hex field")
        let black = app.buttons["colourGrid.0.11"].tap(until: { app.buttons["colourRow.Tiles"].value as? String == "#000000" })
        XCTAssertTrue(black, "the pick didn't reach the setting")
        XCTAssertEqual(field.value as? String, "000000", "the hex field didn't follow the pick")
        closePicker(app)
        if pageShows {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertLessThan(screenBrightness(at: bar), 0.15, "the page didn't take the picked tile colour")
        }
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        XCTAssertEqual(app.buttons["colourRow.Tiles"].value as? String, "#FFFFFF", "Reset didn't put white back")
        if pageShows {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertGreaterThan(screenBrightness(at: bar), 0.4, "the page didn't go back to white tiles")
        }
        setSwitch(toggle, on: false)
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        guard (toggle.value as? String == "1") != on else { return }
        // The switch itself: a tap on the row's middle lands on its label.
        let control = toggle.switches.firstMatch
        let target = control.exists ? control : toggle
        _ = target.waitForHittable(timeout: 5)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "Custom Colors didn't switch")
    }
}
