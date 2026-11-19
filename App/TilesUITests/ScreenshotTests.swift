import XCTest

/// Captures screenshots in portrait and landscape for every configured device.
/// Attachments are kept always so xcresulttool can export them.
/// This test never fails due to visual differences — it only fails if the app
/// doesn't reach a usable state.
@MainActor
final class ScreenshotTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }
    /// Upright again for whatever runs next: left on its side, Settings shows in landscape on an iPhone,
    /// where its rows are out of reach.
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    // MARK: - Helpers

    private func launchWithDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        XCTAssertTrue(
            app.staticTexts["23.98"].firstMatch.waitForExistence(timeout: 15),
            "demo camera didn't become ready"
        )
        return app
    }

    private func capture(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: - Tests

    func testPortraitScreenshots() {
        XCUIDevice.shared.orientation = .portrait
        settle()
        let app = launchWithDemo()

        // Normal dashboard
        capture(name: "portrait-normal")

        // Edit mode
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "Edit mode didn't open")
        settle()
        capture(name: "portrait-edit")
        app.buttons["Done"].tap()
        settle()

        // Settings sheet
        app.buttons["Settings"].tap()
        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 5),
            "Settings sheet didn't open"
        )
        settle()
        capture(name: "portrait-settings")
        // Dismiss settings
        let doneButtons = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Done'"))
        if doneButtons.firstMatch.exists {
            doneButtons.firstMatch.tap()
        } else {
            app.swipeDown()
        }
        settle()
    }

    func testLandscapeScreenshots() {
        XCUIDevice.shared.orientation = .landscapeLeft
        settle()
        let app = launchWithDemo()

        // Normal dashboard
        capture(name: "landscape-normal")

        // Edit mode
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "Edit mode didn't open")
        settle()
        capture(name: "landscape-edit")
        app.buttons["Done"].tap()
        settle()
    }

    /// The four demo cameras' A+B page: one camera at a time on a phone (upright or on its side), side by side on an iPad.
    func testLineupScreenshots() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            settle()
            let app = XCUIApplication()
            app.launchArguments += ["-CCDebugDemoLineup", "YES"]
            app.launch()
            let page = app.buttons["A+B"]
            XCTAssertTrue(page.waitForExistence(timeout: 10), "no A+B page")
            page.tap()
            settle()
            capture(name: "\(name)-lineup")
            // One camera at a time (a phone on its side): camera B, from its chip, so a page that lands off by a margin
            // shows.
            let chipB = app.buttons["Show Camera B"]
            if chipB.exists {
                chipB.tap()
                settle()
                capture(name: "\(name)-lineup-b")
            }
            app.buttons["Edit Tiles"].tap()
            XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "Edit mode didn't open")
            settle()
            capture(name: "\(name)-lineup-edit")
            app.buttons["Done"].tap()
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// A PYXIS's page with the camera offline in Test Mode (a working demo of itself), in use and in
    /// edit mode, upright and on its side. `-CCDebugOfflinePYXIS` gives the app a store of its own, so the demo FX3 the
    /// other tests use is left alone.
    func testTestModeScreenshots() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            settle()
            let app = XCUIApplication()
            app.launchArguments += ["-CCDebugOfflinePYXIS", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["Test Mode is on"].waitForExistence(timeout: 15), "no TEST badge")
            XCTAssertTrue(app.staticTexts["PYXIS 12K demo"].firstMatch.waitForExistence(timeout: 10), "no PYXIS demo")
            settle()
            capture(name: "\(name)-pyxis-test")
            app.buttons["Edit Tiles"].tap()
            XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "Edit mode didn't open")
            settle()
            capture(name: "\(name)-pyxis-edit")
            app.buttons["Done"].tap()
            app.terminate()
        }
    }
}
