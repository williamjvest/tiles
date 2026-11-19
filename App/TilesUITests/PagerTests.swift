import XCTest

/// An iPhone shows a page of several cameras one at a time. Editing works on the camera shown; Done brings the pager
/// back on that camera (Done must not silently switch to a different camera than the one being edited).
/// Two working demo cameras held in memory (`-CCDebugDemoBodies`), so nothing saved is touched. iPhone only.
@MainActor
final class PagerTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    func testDoneKeepsTheCameraThatWasShowing() throws {
        try doneKeepsTheCamera()
    }

    /// On its side the phone shows each camera's short page (`shortPager`), the same way.
    func testDoneKeepsTheCameraThatWasShowingLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try doneKeepsTheCamera()
    }

    private func doneKeepsTheCamera() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "an iPad shows a page's cameras side by side")
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", "fx3,venice2"]
        app.launch()
        let chipB = app.buttons["cameraSwitcher.B"].firstMatch
        XCTAssertTrue(chipB.waitForExistence(timeout: 15), "no camera switcher (an iPhone shows one camera at a time)")
        let window = app.windows.firstMatch.frame

        chipB.tap()
        XCTAssertTrue(onScreen(app.staticTexts["VENICE 2 demo"], in: window), "B didn't come into view")

        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(onScreen(app.staticTexts["VENICE 2 demo"], in: window), "editing isn't on B")
        app.buttons["Done"].tap()

        XCTAssertTrue(onScreen(app.staticTexts["VENICE 2 demo"], in: window), "Done went back to another camera")
        XCTAssertFalse(onScreen(app.staticTexts["FX3 demo"], in: window, wait: 1), "Done shows A")
        XCTAssertEqual(chipB.value as? String, "Showing", "the switcher doesn't light B")
    }

    /// Within the window across, once scrolling has settled.
    private func onScreen(_ element: XCUIElement, in window: CGRect, wait: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if element.exists {
                let frame = element.frame
                if frame.minX >= window.minX - 1 && frame.maxX <= window.maxX + 1 { return true }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}
