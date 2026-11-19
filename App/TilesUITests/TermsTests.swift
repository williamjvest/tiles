import XCTest

/// The Terms of Use: a sheet that can't be swiped away, Sony's two terms first, one Agree, and Settings → About Tiles
/// with the terms, Tiles' license and the third-party notices. Over the demo lineup held in memory, so nothing is saved.
@MainActor
final class TermsTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testAgreeOnceThenAboutHasItAll() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoLineup", "YES", "-CCDebugShowTerms", "YES"]
        app.launch()

        let agree = app.buttons["terms.agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 15), "no Terms of Use sheet")
        XCTAssertTrue(app.staticTexts["Sony cameras and their warranty"].exists, "Sony's warranty term isn't first")
        XCTAssertTrue(app.staticTexts["No weapons or military use"].exists, "Sony's prohibited uses aren't there")
        attach(app, "Terms of Use")

        // A swipe down doesn't dismiss it: only Agree does.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(agree.waitForExistence(timeout: 2), "the sheet was swiped away")

        XCTAssertTrue(agree.tap(until: { !agree.exists }), "Agree didn't close the sheet")
        XCTAssertTrue(app.buttons["Settings"].waitForHittable(timeout: 5), "the dashboard isn't usable after Agree")

        app.buttons["Settings"].tap()
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'About Tiles'")).firstMatch
        for _ in 0..<8 where !about.exists || !about.isHittable { app.swipeUp() }
        XCTAssertTrue(about.waitForExistence(timeout: 5), "no About Tiles in Settings")
        about.tap()
        for row in ["Terms of Use", "License", "Acknowledgments"] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "About has no \(row)")
        }
        attach(app, "About Tiles")
        app.buttons["Acknowledgments"].tap()
        let libssh2 = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'libssh2'")).firstMatch
        XCTAssertTrue(libssh2.waitForExistence(timeout: 5), "the acknowledgements don't credit libssh2")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
