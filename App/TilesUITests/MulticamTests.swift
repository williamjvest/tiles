import XCTest

/// A page of VENICEs: two working demo VENICE 2s side by side (`-CCDebugDemoBodies`), held in memory, so nothing saved
/// is touched. Linked, as a page of FX3s or an FX3 and a PYXIS is.
@MainActor
final class MulticamTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ bodies: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", bodies]
        app.launch()
        let demo = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'VENICE 2 demo'")).firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 15), "no demo VENICE")
        return app
    }

    /// The chain in the top bar turns linking on for the page.
    private func turnLinkingOn(_ app: XCUIApplication) {
        app.buttons["Link Cameras"].tap()
        let on = app.buttons["Link Cameras on This Page"]
        XCTAssertTrue(on.waitForExistence(timeout: 3), "no link menu")
        on.tap()
    }

    /// REC on camera A rolls B as well, and STOP stops both.
    func testLinkedRECRollsBothVENICEs() {
        let app = launch("venice2,venice2")
        turnLinkingOn(app)
        let rec = app.buttons.matching(NSPredicate(format: "label == 'REC'"))
        let stop = app.buttons.matching(NSPredicate(format: "label == 'STOP'"))
        XCTAssertTrue(rec.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rec.count, 2, "two REC buttons")
        rec.firstMatch.tap()
        let both = NSPredicate { _, _ in stop.count == 2 }
        wait(for: [expectation(for: both, evaluatedWith: nil)], timeout: 8)
        stop.firstMatch.tap()
        let neither = NSPredicate { _, _ in rec.count == 2 }
        wait(for: [expectation(for: neither, evaluatedWith: nil)], timeout: 8)
        app.terminate()
    }

    /// A project rate restarts a VENICE, and a page that links frame rate sends it to both: the confirmation names both
    /// cameras, not "the camera".
    func testALinkedProjectRateNamesEveryCameraItRestarts() {
        let app = launch("venice2,venice2")
        turnLinkingOn(app)
        let fps = app.staticTexts["24"].firstMatch
        XCTAssertTrue(fps.waitForExistence(timeout: 5), "no frame rate tile at 24")
        fps.tap()
        let rate = app.buttons["25"]
        XCTAssertTrue(rate.waitForExistence(timeout: 3), "the frame rate menu didn't open")
        rate.tap()
        XCTAssertTrue(app.buttons["Switch to 25 (restarts cameras A and B)"].waitForExistence(timeout: 3),
                      "the confirmation doesn't name both cameras")
        // Left unanswered: iOS 26's dialog has no "Cancel" to tap, and the demos are held in memory.
        app.terminate()
    }
}
