import XCTest

/// VoiceOver on each demo body's page: every button has a name it can say, and Apple's accessibility audit finds no
/// control it can't make sense of. The audit's other findings are printed (`A11Y|` lines) but not failed, as they're
/// design decisions: tiles size their type to the tile (Settings → Appearance → Text Size) rather than to the system's
/// Dynamic Type, and the colors are the style guide's.
@MainActor
final class AccessibilityTests: XCTestCase {
    private let bodies = ["fx3", "fx6", "burano", "venice2", "pyxis12K", "alexa35"]

    override func setUp() async throws { continueAfterFailure = true }

    private func launch(_ body: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CCDebugDemoBodies", body]
        app.launch()
        XCTAssertTrue(app.buttons["Edit Tiles"].waitForExistence(timeout: 15), "\(body): no dashboard")
        Thread.sleep(forTimeInterval: 3)   // the demo camera's values coming in
        return app
    }

    /// No button without a name, nor one named by its symbol ("gobackward.5"). A button inside a named one is the
    /// same control (a menu's own button under the tile's).
    func testEveryButtonHasAName() throws {
        for body in bodies {
            let app = launch(body)
            var nameless: [String] = []
            func walk(_ node: XCUIElementSnapshot, inNamedButton: Bool) {
                let isButton = node.elementType == .button
                if isButton && node.label.isEmpty && !inNamedButton {
                    nameless.append("a button at \(node.frame) \(node.identifier)")
                }
                if isButton && node.label.range(of: #"^[a-z][a-z0-9]*(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil {
                    nameless.append("\"\(node.label)\"")
                }
                for child in node.children { walk(child, inNamedButton: inNamedButton || isButton && !node.label.isEmpty) }
            }
            walk(try app.snapshot(), inNamedButton: false)
            XCTAssertEqual(nameless, [], "\(body): buttons VoiceOver can't name")
            app.terminate()
        }
    }

    /// Apple's audit: a control (anything but a read-out of the camera's value, "23.98" or "f/4.0" as the camera
    /// writes it) that it finds undescribed, undetectable or with the wrong traits fails.
    func testAudit() throws {
        for body in bodies {
            let app = launch(body)
            try app.performAccessibilityAudit(for: .all) { issue in
                let element = issue.element
                print("A11Y|" + [body, "\(issue.auditType.rawValue)", issue.compactDescription,
                                  "\(element?.elementType.rawValue ?? 0)", element?.identifier ?? "",
                                  element?.label ?? ""].joined(separator: "|"))
                let unreadable: XCUIAccessibilityAuditType = [.sufficientElementDescription, .elementDetection, .trait]
                return !(unreadable.contains(issue.auditType) && element?.elementType != .staticText)
            }
            app.terminate()
        }
    }
}
