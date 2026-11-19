import XCTest

/// Tiles' color picker (`ColourPickerPanel`): its close button, and it's gone.
@MainActor
func closePicker(_ app: XCUIApplication) {
    let close = app.buttons["colourPickerClose"]
    XCTAssertTrue(close.waitForExistence(timeout: 5), "the colour picker has no close button")
    XCTAssertTrue(close.tap(until: { !close.exists }), "the colour picker didn't close")
}

/// The screen's brightness at a point, 0 (black) to 1 (white).
@MainActor
func screenBrightness(at point: CGPoint) -> CGFloat {
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

/// The Terms of Use sheet that a launch on the device's own setup shows until it's agreed to, once per install: agreed
/// to, so the test can reach the dashboard. A setup held in memory (`-CCDebugDemoBodies` and the like) never shows it.
@MainActor
func agreeToTermsIfAsked(_ app: XCUIApplication) {
    let agree = app.buttons["terms.agree"]
    guard agree.waitForExistence(timeout: 4) else { return }
    XCTAssertTrue(agree.tap(until: { !agree.exists }), "the Terms of Use sheet didn't close on Agree")
}

extension XCUIElement {
    /// A tap into a menu or popover that has just come up: waits out its entrance first, then taps, and taps once more
    /// only if `done` still isn't true and this is still there to tap. UIKit drops touches while a presentation is
    /// still animating in, and a test that finds the element on its first poll can tap mid-animation (the
    /// color picker's close, a grid color and a menu item each miss now and then). A tap that never lands
    /// still fails, and nothing is tapped after it has gone.
    @discardableResult
    func tap(until done: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
        Thread.sleep(forTimeInterval: 0.6)
        for attempt in 0..<2 {
            if attempt == 1 && !(exists && isHittable) { return done() }
            tap()
            let met = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done() }, object: nil)
            if XCTWaiter().wait(for: [met], timeout: timeout) == .completed { return true }
        }
        return false
    }

    /// Waits until a tap would land on it (not covered by a sheet on its way out, not scrolled away).
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let hittable = NSPredicate(format: "hittable == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: self)], timeout: timeout) == .completed
    }
}
