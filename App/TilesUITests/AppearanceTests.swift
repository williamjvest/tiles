import XCTest

/// Settings → Appearance: custom colors switched on redraw the page behind the sheet at
/// once, and a relaunch comes back on them. Read off the top bar's left end, which is bar and nothing else: black in the
/// standard look, the tiles' white with custom colors. Against the app's own setup, since what's saved is the point;
/// it leaves custom colors off, as it found them. iPad only: on a phone the sheet covers the page.
@MainActor
final class AppearanceTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testCustomColoursRedrawThePageAndSurviveARelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "no Settings button")
        try XCTSkipIf(app.windows.firstMatch.frame.width < 700, "the sheet covers the whole page on a phone")
        let bar = CGPoint(x: 6, y: settings.frame.midY)

        setCustomColours(false, app)  // whatever an earlier run left
        XCTAssertLessThan(brightness(at: bar), 0.15, "the standard look's top bar isn't black")

        settings.tap()
        openAppearance(app)
        switchCustomColours(to: true, app)
        // From the daylight set whatever an earlier run left picked: the brightness checks below read its white tiles.
        let reset = app.buttons["Reset Colors"]
        if reset.exists && reset.isEnabled { reset.tap() }
        Thread.sleep(forTimeInterval: 1)
        // Under the sheet's dimming: the white bar reads a mid gray, the black one stayed black.
        XCTAssertGreaterThan(brightness(at: bar), 0.4, "the page didn't redraw behind the sheet")
        close(app)
        XCTAssertGreaterThan(brightness(at: bar), 0.9, "the top bar isn't the tiles' white")

        app.terminate()
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(brightness(at: bar), 0.9, "custom colours weren't saved")

        setCustomColours(false, app)
        XCTAssertLessThan(brightness(at: bar), 0.15, "switching them off didn't bring the standard look back")
    }

    /// Settings → Appearance → Custom Colors, then back to the page.
    private func setCustomColours(_ on: Bool, _ app: XCUIApplication) {
        app.buttons["Settings"].tap()
        openAppearance(app)
        switchCustomColours(to: on, app)
        close(app)
    }

    private func openAppearance(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Appearance row in Settings")
        row.tap()
        XCTAssertTrue(app.switches["Custom Colors"].waitForExistence(timeout: 5), "Appearance didn't open")
    }

    private func switchCustomColours(to on: Bool, _ app: XCUIApplication) {
        let toggle = app.switches["Custom Colors"]
        guard (toggle.value as? String == "1") != on else { return }
        // The switch itself: a tap on the row's middle lands on its label, which doesn't switch it.
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "Custom Colors didn't switch")
    }

    /// Back out of Appearance, and Done.
    private func close(_ app: XCUIApplication) {
        app.navigationBars["Appearance"].buttons.firstMatch.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done in Settings")
        done.tap()
        Thread.sleep(forTimeInterval: 1)  // the sheet slides away
    }

    /// The screen's brightness at a point, 0 (black) to 1 (white).
    private func brightness(at point: CGPoint) -> CGFloat {
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage else { return -1 }
        let scale = CGFloat(cg.width) / image.size.width
        let x = Int(point.x * scale), y = Int(point.y * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(cg, in: CGRect(x: -x, y: y + 1 - cg.height, width: cg.width, height: cg.height))
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }
}
