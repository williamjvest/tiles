import XCTest

/// The tiling system and clip naming on a device, against the demo FX3: editing doesn't move a tile, a tile added
/// from Add Tile is brought into view, and the Naming tile sets the camera's title. Each test leaves the setup as
/// it found it.
@MainActor
final class TilingTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launchWithDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        XCTAssertTrue(app.staticTexts["23.98"].firstMatch.waitForExistence(timeout: 15), "no frame rate tile")
        return app
    }

    /// Back to the automatic layout, whatever an earlier run (or a failed test) left. Edit mode ends with it.
    private func resetLayout(_ app: XCUIApplication) {
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        // On an upright iPhone, Reset is under ⋯ ("More"). Its menu animates in, and a tap on Reset before it has
        // settled can miss it and leave the menu open with no confirmation (iPhone 17 Pro).
        if !app.buttons["Reset"].exists {
            app.buttons["More"].tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        app.buttons["Reset"].tap()
        // A loaded machine animates slower: a tap that still missed gets one more go, menu and all.
        if !app.buttons["Reset Layout"].waitForExistence(timeout: 3) {
            if !app.buttons["Reset"].exists {
                app.buttons["More"].tap()
                Thread.sleep(forTimeInterval: 1.5)
            }
            app.buttons["Reset"].tap()
        }
        XCTAssertTrue(app.buttons["Reset Layout"].waitForExistence(timeout: 5), "no Reset Layout confirmation")
        app.buttons["Reset Layout"].tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// A monitoring tile's outputs (edit mode): the checklist stays open while outputs are ticked, the chip names
    /// them, and All Outputs puts it back. On the offline PYXIS,
    /// whose LCD, USB-C and SDI outputs set their overlays one by one.
    func testOutputsChecklistStaysOpen() {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugOfflinePYXIS", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["PYXIS 12K demo"].firstMatch.waitForExistence(timeout: 15), "no PYXIS demo")
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Outputs: All Outputs'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no outputs chip")
        chip.tap()
        let sdi = app.buttons["SDI"].firstMatch
        let lcd = app.buttons["LCD"].firstMatch
        XCTAssertTrue(sdi.waitForExistence(timeout: 5), "the checklist didn't open")
        sdi.tap()
        XCTAssertTrue(lcd.waitForExistence(timeout: 2), "the checklist closed after one pick")
        lcd.tap()
        XCTAssertTrue(sdi.waitForExistence(timeout: 2), "the checklist closed after the second pick")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Outputs: LCD + SDI. Change'")).firstMatch
                        .waitForExistence(timeout: 3), "the chip doesn't name both outputs")
        app.buttons["All Outputs"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Outputs: All Outputs'")).firstMatch
                        .waitForExistence(timeout: 3), "All Outputs didn't put it back")
        app.terminate()
    }

    func testEditingKeepsEveryTileWhereItWas() {
        let app = launchWithDemo()
        let tiles = ["23.98", "800", "180°"].map { app.staticTexts[$0].firstMatch }
        let before = tiles.map { $0.frame }
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        Thread.sleep(forTimeInterval: 1)
        let during = tiles.map { $0.frame }
        app.buttons["Done"].tap()
        for (old, new) in zip(before, during) {
            XCTAssertEqual(old.minX, new.minX, accuracy: 1)
            XCTAssertEqual(old.minY, new.minY, accuracy: 1)
            XCTAssertEqual(old.height, new.height, accuracy: 1)
        }
    }

    func testAnAddedTileIsBroughtIntoView() {
        let app = launchWithDemo()
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5))
        removeTiles("Live View Button", app)
        app.buttons["Add Tile"].tap()
        XCTAssertTrue(app.navigationBars["Add Tile"].waitForExistence(timeout: 5))
        // The list is alphabetical and longer than the sheet: scroll to the row. "On screen" is its middle inside the
        // list's frame: asked of a row still being laid out (the sheet just opened), isHittable fails the test itself.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let row = list.buttons["Live View Button"]  // the list's row, not a tile behind the sheet
        let onScreen = { row.exists && list.frame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) }
        for _ in 0..<6 where !onScreen() { list.swipeUp() }
        XCTAssertTrue(onScreen(), "Live View Button isn't in Add Tile")
        row.tap()
        let added = app.staticTexts["Live View Button"].firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)  // the sheet closes, then the page scrolls
        XCTAssertTrue(added.isHittable, "the new tile is off screen")
        removeTiles("Live View Button", app)
        app.buttons["Done"].tap()
    }

    /// The Lock tile: the top bar's padlock on the page, one lock between them. Locked, the other tiles
    /// take no taps (the frame rate's menu doesn't open); the Lock tile still takes one, and unlocks them.
    func testTheLockTileLocksAndUnlocksThePage() {
        let app = launchWithDemo()
        resetLayout(app)
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        removeTiles("Lock", app)
        app.buttons["Add Tile"].tap()
        XCTAssertTrue(app.navigationBars["Add Tile"].waitForExistence(timeout: 5))
        let row = app.collectionViews.buttons["Lock"]  // the list's row, not a Lock tile behind the sheet
        for _ in 0..<6 where !row.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.isHittable, "Lock isn't in Add Tile")
        row.tap()
        Thread.sleep(forTimeInterval: 2)  // the sheet closes, then the page scrolls
        app.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 1)

        let tile = app.buttons["Lock"].firstMatch
        let fps = app.staticTexts["23.98"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "no Lock tile on the page")
        XCTAssertEqual(tile.value as? String, "Unlocked")
        tile.tap()
        XCTAssertEqual(tile.value as? String, "Locked")
        XCTAssertTrue(app.buttons["Unlock Controls"].exists, "the padlock in the top bar didn't lock with the tile")
        fps.tap()
        XCTAssertFalse(app.buttons["29.97"].waitForExistence(timeout: 2), "a locked tile opened its menu")

        tile.tap()
        XCTAssertEqual(tile.value as? String, "Unlocked", "the Lock tile didn't unlock")
        XCTAssertTrue(app.buttons["Lock Controls"].exists, "the padlock in the top bar didn't unlock with the tile")
        fps.tap()
        XCTAssertTrue(app.buttons["29.97"].waitForExistence(timeout: 3), "the frame rate's menu didn't open once unlocked")
        app.buttons["23.98"].firstMatch.tap()  // the rate it's on: closes the menu, changes nothing

        // The padlock above locks the tile's lock too, and the tile undoes it. Tapped once the frame rate's menu has
        // gone: a tap during its close can miss (iPhone 17 Pro).
        XCTAssertTrue(app.buttons["Lock Controls"].tap(until: { tile.value as? String == "Locked" }),
                      "the tile didn't follow the padlock")
        tile.tap()
        XCTAssertEqual(tile.value as? String, "Unlocked")
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        removeTiles("Lock", app)
        app.buttons["Done"].tap()
    }

    /// Edit mode: takes every tile of a kind off the page, by its ×. On a phone Reset only puts the phone's own
    /// arrangement back, and a tile added there is on the page too: tests that only reset left their tiles on the page,
    /// where the phone's column shows them (six Live View Buttons on the iPhone simulator if left there).
    private func removeTiles(_ title: String, _ app: XCUIApplication) {
        let remove = app.buttons["Remove \(title)"]
        for _ in 0..<10 where remove.firstMatch.exists {
            remove.firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Edit mode: a tile dropped on another of its size swaps with it, rather than being refused.
    /// The demo FX3's ISO and shutter dial are side by side and the same size on an iPad's page.
    func testDroppingATileOnAnotherSwapsThem() throws {
        let app = launchWithDemo()
        resetLayout(app)
        let iso = app.staticTexts["800"].firstMatch, shutter = app.staticTexts["180°"].firstMatch
        XCTAssertTrue(iso.waitForExistence(timeout: 5) && shutter.exists, "no ISO or shutter tile")
        let isoBefore = iso.frame, shutterBefore = shutter.frame
        guard abs(isoBefore.midY - shutterBefore.midY) < 60, shutterBefore.midX > isoBefore.midX else {
            throw XCTSkip("ISO and shutter aren't side by side on this page")
        }
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        Thread.sleep(forTimeInterval: 1)
        let from = iso.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Rest on the shutter tile, as a finger would: the page makes room while the tile is still held.
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 1)
        let isoAfter = iso.frame, shutterAfter = shutter.frame
        XCTAssertGreaterThan(isoAfter.midX, isoBefore.midX + 40, "ISO didn't move to the shutter's place")
        XCTAssertLessThan(shutterAfter.midX, shutterBefore.midX - 40, "the shutter didn't move to ISO's place")
        XCTAssertEqual(isoAfter.minY, isoBefore.minY, accuracy: 2)
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Reset"].waitForExistence(timeout: 5))
        app.buttons["Reset"].tap()
        app.buttons["Reset Layout"].tap()
    }

    /// Undo puts a swap back: one drag can move several tiles.
    func testUndoPutsASwapBack() throws {
        let app = launchWithDemo()
        resetLayout(app)
        let iso = app.staticTexts["800"].firstMatch, shutter = app.staticTexts["180°"].firstMatch
        XCTAssertTrue(iso.waitForExistence(timeout: 5) && shutter.exists, "no ISO or shutter tile")
        let isoBefore = iso.frame, shutterBefore = shutter.frame
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.exists && !undo.isEnabled, "Undo should be there, with nothing to undo yet")
        Thread.sleep(forTimeInterval: 1)
        let from = iso.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(iso.frame.midY * 1000 + iso.frame.midX, isoBefore.midY * 1000 + isoBefore.midX, "nothing moved")
        XCTAssertTrue(undo.isEnabled, "Undo didn't light up after a move")
        undo.tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(iso.frame.midX, isoBefore.midX, accuracy: 2)
        XCTAssertEqual(iso.frame.midY, isoBefore.midY, accuracy: 2)
        XCTAssertEqual(shutter.frame.midX, shutterBefore.midX, accuracy: 2)
    }

    /// A tile carried to the bottom edge and held there scrolls the page under it, so it can be
    /// dropped in edit mode's spare rows below the fold.
    func testATileHeldAtTheBottomEdgeScrollsThePage() throws {
        let app = launchWithDemo()
        let iso = app.staticTexts["800"].firstMatch
        let rec = app.buttons.matching(NSPredicate(format: "label CONTAINS 'REC'")).firstMatch
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'demo'")).firstMatch
        XCTAssertTrue(iso.waitForExistence(timeout: 5) && rec.exists && label.exists, "no ISO, REC or camera label")
        resetLayout(app)
        let isoBefore = iso.frame
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        Thread.sleep(forTimeInterval: 1)
        let top = label.frame.minY
        let window = app.windows.firstMatch
        let from = iso.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Inside the page's bottom edge, clear of the home indicator.
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: -60))
        from.press(forDuration: 0.2, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 3)
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "after-edge-hold"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertLessThan(label.frame.minY, top - 20, "the page didn't scroll under the held tile")
        app.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        // At the bottom of the page: below REC where there's room, or in REC's place on a short phone (an SE), where the
        // page's spare rows are all the scrolling there is and the drop lands on REC, which moves down for it.
        XCTAssertGreaterThan(iso.frame.minY, isoBefore.minY + 200, "ISO didn't go to the bottom of the page")
        // Put the page back.
        resetLayout(app)
    }

    /// A phone on its side shows a page of several cameras one at a time, as wide as the screen, picked
    /// from the chips in the top bar; edit mode keeps the shown camera's tiles where they were.
    func testALandscapePhoneShowsOneCameraAtATime() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        Thread.sleep(forTimeInterval: 1)
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoLineup", "YES"]
        app.launch()
        let page = app.buttons["A+B"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "no A+B page")
        page.tap()
        let chipB = app.buttons["Show Camera B"]
        guard chipB.waitForExistence(timeout: 5) else {
            throw XCTSkip("not a short screen on its side (an iPad): both cameras fit")
        }
        let a = app.staticTexts["BURANO demo"].firstMatch, b = app.staticTexts["FX6 demo"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        // On screen by frame: XCUITest can't say whether an element scrolled out of view is hittable, it fails instead.
        let window = app.windows.firstMatch.frame
        func shown(_ element: XCUIElement) -> Bool {
            element.exists && window.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }
        XCTAssertTrue(shown(a), "camera A isn't shown")
        XCTAssertFalse(shown(b), "camera B is shown beside A")
        chipB.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(shown(b), "the chip didn't show camera B")
        XCTAssertFalse(shown(a), "camera A is still shown")
        let before = b.frame
        app.buttons["Edit Tiles"].tap()
        XCTAssertTrue(app.buttons["Add Tile"].waitForExistence(timeout: 5), "edit mode didn't open")
        Thread.sleep(forTimeInterval: 1)
        let during = app.staticTexts["FX6 demo"].firstMatch.frame
        XCTAssertEqual(during.minX, before.minX, accuracy: 1)
        XCTAssertEqual(during.minY, before.minY, accuracy: 1)
        app.buttons["Done"].tap()
    }

    func testNamingSetsTheTitle() throws {
        let app = launchWithDemo()
        let next = app.staticTexts["C0007"].firstMatch
        guard next.waitForExistence(timeout: 5) else {
            // The iPhone's column has no Naming tile; it's in Add Tile there.
            throw XCTSkip("no Naming tile on this page")
        }
        next.tap()
        XCTAssertTrue(app.navigationBars["Clip Naming"].waitForExistence(timeout: 5), "Clip Naming didn't open")
        // Typing adds to the title wherever the cursor lands; whatever the camera ends up with, the next clip follows it.
        // The demo camera starts over on every launch, so nothing needs putting back.
        let field = app.textFields["clip-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "no title field")
        field.tap()
        field.typeText("X\n")
        let title = field.value as? String ?? ""
        XCTAssertTrue(title.count == 2 && title.contains("X"), "title is \(title)")
        XCTAssertTrue(app.staticTexts[title + "0007"].waitForExistence(timeout: 5), "the next clip didn't follow the title")
        app.buttons["Done"].tap()
    }
}
