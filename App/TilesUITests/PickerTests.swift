import XCTest

/// The demo camera re-sends its state every 2 s. Open the frame rate picker, leave it open 6 s, then pick.
@MainActor
final class PickerTests: XCTestCase {
    func testPickerSurvivesStateUpdates() {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 15) { demo.tap() }
        let value = app.staticTexts["23.98"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 15), "no frame rate tile")
        Thread.sleep(forTimeInterval: 3)
        value.tap()
        let item = app.buttons["29.97"]
        let opened = item.waitForExistence(timeout: 3)
        Thread.sleep(forTimeInterval: 6)
        // Still open: its option is still listed. Not `isHittable`, which can come back false with the menu
        // plainly open, so the tap goes to the option's own point.
        let stillOpen = item.waitForExistence(timeout: 2)
        if stillOpen { item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let picked = app.staticTexts["29.97"].waitForExistence(timeout: 4)
        if !picked {
            let rates = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '.'")).allElementsBoundByIndex.map { $0.label }
            print("RESULT-RATES " + rates.joined(separator: " | "))
        }
        print("RESULT-" + "Z opened=\(opened) stillOpen=\(stillOpen) picked=\(picked)")
        XCTAssertTrue(opened && stillOpen && picked)
    }
}
