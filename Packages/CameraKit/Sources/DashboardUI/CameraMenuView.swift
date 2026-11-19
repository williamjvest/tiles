import SwiftUI
import CameraCore

/// The camera's own buttons, pressed for it (`CameraState.cameraButtons`): the BURANO's MENU, Home, Back, Display,
/// Clips and multi-selector; a VENICE's MENU, Home, Cancel (as Back), the arrows and Set (as the middle), so its menu
/// can be worked without standing at the camera. Only the buttons the camera lists are
/// drawn. A sheet, so it keeps the standard look (`Theme.sheet`; SheetColourTests checks this file).
struct CameraMenuView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    /// The row across the top, and the multi-selector under it.
    private static let row: [CameraBodyButton] = [.menu, .home, .back, .display, .clips]
    private static let pad: [CameraBodyButton] = [.up, .down, .left, .right, .enter]

    var body: some View {
        let buttons = camera.state.cameraButtons
        NavigationStack {
            Form {
                if Self.row.contains(where: buttons.contains) {
                    Section {
                        HStack(spacing: 8) {
                            ForEach(Self.row.filter(buttons.contains), id: \.self) { key($0) }
                        }
                    } footer: {
                        // A BURANO's MENU is held (`SonyCameraBackend.pressBodyButton`); a VENICE's is one press.
                        if !CameraProfile.isVenice(camera.state.model) {
                            FooterText("Menu is pressed and held, as on the camera, to open the full menu.")
                        }
                    }
                }
                if Self.pad.contains(where: buttons.contains) {
                    Section {
                        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow { Color.clear; key(.up); Color.clear }
                            GridRow { key(.left); key(.enter); key(.right) }
                            GridRow { Color.clear; key(.down); Color.clear }
                        }
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)
                    } header: {
                        // A VENICE has up, down and Set, not a multi-selector.
                        if buttons.contains(.left) || buttons.contains(.right) { Text("Multi-Selector") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Camera Menu")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// One of the camera's buttons. Bordered, so each button in a row takes its own taps rather than the row's.
    private func key(_ button: CameraBodyButton) -> some View {
        let has = camera.state.cameraButtons.contains(button)
        return Button { camera.send(.pressCameraButton(button)) } label: {
            VStack(spacing: 3) {
                Image(systemName: button.symbol)
                    .font(.system(size: 17, weight: .semibold))
                if let title = button.title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .disabled(!camera.state.connection.isControllable || !has)
        .opacity(has ? 1 : 0)
        .accessibilityLabel(button.name)
    }
}

private extension CameraBodyButton {
    var symbol: String {
        switch self {
        case .menu: "line.3.horizontal"
        case .home: "house"
        case .back: "arrow.uturn.backward"
        case .display: "info.circle"
        case .clips: "square.grid.2x2"
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .enter: "smallcircle.filled.circle"
        }
    }

    /// Under the symbol in the top row; the multi-selector's arrows need none.
    var title: String? {
        switch self {
        case .menu: "Menu"
        case .home: "Home"
        case .back: "Back"
        case .display: "Display"
        case .clips: "Clips"
        case .up, .down, .left, .right, .enter: nil
        }
    }

    var name: String {
        switch self {
        case .menu: "Menu"
        case .home: "Home"
        case .back: "Back"
        case .display: "Display"
        case .clips: "Clips"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .enter: "Enter"
        }
    }
}
