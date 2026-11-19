import XCTest

/// A camera's own color: the ninth swatch in Edit Camera, an eyedropper, opens Tiles' color picker
/// from it (`ColourPickerPanel`; see AppearancePickerTests for why not Apple's).
/// Against the app's own setup; it cancels out of the picker and the editor, so the camera keeps its color.
@MainActor
final class CustomColourTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testTheEyedropperSwatchOpensTheColourPicker() throws {
        let app = XCUIApplication()
        app.launch()
        agreeToTermsIfAsked(app)
        let demo = app.buttons["Try a Demo Camera"]
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "no Settings button")
        settings.tap()

        // The first camera in Settings → Cameras opens Edit Camera.
        let camera = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo'")).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "no camera row in Settings")
        camera.tap()

        let swatch = app.descendants(matching: .any).matching(identifier: "customColour").firstMatch
        XCTAssertTrue(swatch.waitForExistence(timeout: 5), "no custom colour swatch in Edit Camera")
        // Where a finger lands, not the element's own tap: what matters is that a touch there reaches the picker.
        swatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Its Grid / Spectrum / Sliders switch, and the grid drawn.
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 5), "the colour picker didn't open")
        XCTAssertTrue(app.buttons["colourGrid.0.11"].exists, "the picker is empty")

        // Out without picking: the picker's close button, then Cancel on the editor.
        closePicker(app)
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
    }
}
