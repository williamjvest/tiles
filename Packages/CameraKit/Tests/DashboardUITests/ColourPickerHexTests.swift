#if os(macOS)
import AppKit
import SwiftUI
import Testing
import CameraCore
@testable import DashboardUI

/// The color picker's hex field follows a pick while it's being edited. On a Mac the field has the focus as soon as the
/// picker opens, and a click on the grid doesn't take it away, so without this the hex stays on the color the picker
/// opened with. An iPhone or iPad moves the focus off the field on a tap, so only a Mac shows it: a
/// real window, the field made first responder, then a pick.
@MainActor
@Suite("Colour picker's hex field")
struct ColourPickerHexTests {
    @Observable final class Pick {
        var rgb = AppearanceSettings.RGB(red: 0.1, green: 0.3, blue: 0)
    }

    struct Host: View {
        @Bindable var pick: Pick
        var body: some View { ColourPickerPanel(title: "Custom Colour", rgb: $pick.rgb) }
    }

    @Test("A pick shows in the field while it has the focus")
    func pickWhileEditing() throws {
        _ = NSApplication.shared
        let pick = Pick()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(pick: pick))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle()
        let field = try #require(Self.textField(in: window.contentView), "no hex field")
        let opened = pick.rgb.hex
        #expect(field.stringValue == opened)
        #expect(window.makeFirstResponder(field), "the hex field didn't take the focus")
        settle()

        pick.rgb = AppearanceSettings.RGB(red: 0.8, green: 0.6, blue: 1)  // a pick from the grid
        settle()
        let editor = window.firstResponder as? NSTextView
        #expect((editor?.string ?? field.stringValue) == "CC99FF", "the field kept the colour the picker opened with")
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    private static func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = textField(in: child) { return found } }
        return nil
    }
}
#endif
