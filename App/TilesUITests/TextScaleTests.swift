import XCTest

/// Settings → Appearance → Text Size's slider makes every tile's small type bigger, on any screen, and puts it back.
/// On a working demo VENICE 2 held in memory, so nothing is saved.
@MainActor
final class TextScaleTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testTheSliderMakesCaptionsBiggerAndBack() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", "venice2"]
        app.launch()
        // ISO's caption: short, so it has the room to grow in any tile (a long one beside a switch gives way).
        let caption = app.staticTexts["ISO"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 15), "no ISO tile")
        let standard = caption.frame.height

        setSlider(app, up: true)
        XCTAssertGreaterThan(caption.frame.height, standard * 1.2, "the slider's top end didn't make the caption bigger")
        setSlider(app, up: false)
        XCTAssertLessThan(caption.frame.height, standard * 1.15, "the slider's bottom end didn't put the caption back")
    }

    /// To the slider's top end or its bottom. A drag to the end lands a step short where the size icons sit inside the
    /// slider (an iPad: 140 %), so the ends are 130–150 % and 100–110 %.
    private func setSlider(_ app: XCUIApplication, up: Bool) {
        app.buttons["Settings"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Appearance row in Settings")
        row.tap()
        let slider = app.sliders["textScale"]
        // The last section: below the fold on a phone or an iPad's sheet, where the form has it but a drag can't reach it.
        for _ in 0..<6 where !slider.exists || !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "no Text Size slider in Appearance")
        slider.adjust(toNormalizedSliderPosition: up ? 1 : 0)
        // The row reads "Size, 140 %".
        let percent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", up ? ".*1[345]0 %" : ".*1[01]0 %"))
        XCTAssertTrue(percent.firstMatch.waitForExistence(timeout: 5), "the slider didn't get to its \(up ? "top" : "bottom") end")
        app.navigationBars.buttons.element(boundBy: 0).tap()  // back to Settings
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForHittable(timeout: 5), "Settings didn't close")
    }
}
