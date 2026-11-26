import SwiftUI
import CameraCore

/// Grab Still: a still frame written to the camera's own card (`CameraCommand.grabStill`), where it has a still capture
/// (a Blackmagic camera's, `CameraState.canGrabStill`). One tap, one still. The camera answers whether it saved it, so
/// the tile says so for a moment: lit and "Saved", or the camera's reason.
struct GrabStillTile: View {
    let camera: CameraController
    @State private var asked: Date?
    @State private var shown: StillGrab?
    @Environment(\.tileScale) private var s

    var body: some View {
        let state = camera.state
        let enabled = state.connection.isControllable && state.canGrabStill
        let waiting = asked != nil && shown == nil
        Tile(tint: camera.slot.tint, fill: shown?.saved == true || waiting ? Theme.engaged : Theme.tile, isEnabled: enabled) {
            GeometryReader { geo in
                let short = geo.size.height < 34 * s
                Button {
                    shown = nil
                    asked = Date()
                    camera.send(.grabStill)
                } label: {
                    Text(label)
                        .font(Theme.buttonLabel(short: short, scale: s))
                        .lineLimit(short ? 1 : 2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(enabled ? Theme.text : Theme.secondaryText)
                        .padding(.horizontal, Theme.inset * s)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled || waiting)
                .accessibilityLabel("Grab Still")
                .accessibilityValue(shown.map { $0.saved ? "Saved" : ($0.message ?? "Not saved") } ?? "")
                .accessibilityHint("Saves a still frame to the camera's card")
            }
        }
        // The answer to this tap: one that came after it.
        .onChange(of: state.lastStill) { _, result in
            guard let asked, let result, result.at >= asked else { return }
            shown = result
            self.asked = nil
        }
        .task(id: shown) {
            guard shown != nil else { return }
            try? await Task.sleep(for: .seconds(shown?.saved == true ? 1.5 : 4))
            shown = nil
        }
        .task(id: asked) {
            // No answer in 10 s: the tile comes back rather than waiting for good.
            guard asked != nil else { return }
            try? await Task.sleep(for: .seconds(10))
            asked = nil
        }
    }

    private var label: String {
        if let shown { return shown.saved ? "Saved" : (shown.message ?? "Not saved") }
        return asked != nil ? "Grabbing…" : "Grab Still"
    }
}
