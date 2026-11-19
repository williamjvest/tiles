import CameraCore
import SwiftUI

// An FX6's own tiles (docs/fx6-controls.md). Add Tile only.

/// The shooting mode. Each mode brings its own white balance, look and exposure, so a change is confirmed first, and
/// none goes out during a take.
struct ShootingModeTile: View {
    let camera: CameraController
    @State private var pending: String?
    @Environment(\.tileScale) private var s

    var body: some View {
        let mode = camera.state.shootingMode
        let live = camera.state.connection.isControllable && mode?.isWritable == true
            && camera.state.recording.state == .idle
        Tile(tint: camera.slot.tint, isEnabled: mode != nil) {
            TileFrame(caption: "Shooting Mode", valueWins: true) { oneLine, size in
                PickerValue(text: mode?.shown ?? "—",
                            size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: mode?.options ?? [], title: { $0 }, isLive: live, multiline: !oneLine) { picked in
                    if picked != mode?.shown { pending = picked }
                }
            }
        }
        .confirmationDialog(pending.map { "Switch to \($0)?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let value = pending {
                Button("Switch to \(value)") {
                    camera.send(.setShootingMode(value))
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            Text("The camera changes to that mode's own white balance, look and exposure.")
        }
    }
}

/// Extended Clear Scan: on or off in the header, and while it's on the frequency, a step either way with − and +.
struct ECSTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let ecs = camera.state.ecs
        let on = ecs?.on.shown == true
        let controllable = camera.state.connection.isControllable
        let steps = controllable && ecs?.canStep == true
        Tile(tint: camera.slot.tint, isEnabled: ecs != nil) {
            TileFrame(caption: "ECS") { oneLine, size in
                HStack(spacing: 4 * s) {
                    step(-1, enabled: steps)
                    Text(on ? ecs?.frequency.map(Format.hertz) ?? "—" : "Off")
                        .font(Theme.value(Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s)))
                        .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                    step(1, enabled: steps)
                }
            } accessory: { _ in
                PillToggle(title: on ? "On" : "Off", lit: on, isEnabled: controllable && ecs?.on.isWritable == true) {
                    camera.send(.setECS(!on))
                }
                .fixedSize()
            }
        }
    }

    private func step(_ by: Int, enabled: Bool) -> some View {
        Button { camera.send(.stepECS(by)) } label: {
            Image(systemName: by < 0 ? "minus" : "plus")
                .font(Theme.symbol(16 * s, weight: .regular))
                .frame(width: 32 * s, height: 32 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.secondaryText.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(by < 0 ? "Lower the ECS frequency" : "Raise the ECS frequency")
    }
}

/// The focus or zoom driven from the tile: held, each arrow drives its way at the speed picked, and letting go stops
/// it. The camera keeps a motor going until it's told to stop, so a held arrow renews the drive every 200 ms and the
/// backend stops the motor when that stops (`CameraCommand.driveFocus`). For the focus, a bar shows where it is, near on
/// the left, and the distance where the lens says.
struct LensDriveTile: View {
    let camera: CameraController
    let zoom: Bool
    @State private var speed = Speed.slow
    @Environment(\.tileScale) private var s

    enum Speed: String, CaseIterable {
        case slow = "Slow", medium = "Med", fast = "Fast"

        var next: Speed { self == .slow ? .medium : self == .medium ? .fast : .slow }
    }

    var body: some View {
        let drive = zoom ? camera.state.zoomDrive : camera.state.focusDrive
        let live = camera.state.connection.isControllable && drive?.isWritable == true
        let fastest = drive?.maxSpeed ?? 1
        let rate = switch speed {
        case .slow: 1
        case .medium: max(fastest / 2, 1)
        case .fast: fastest
        }
        Tile(tint: camera.slot.tint, isEnabled: drive != nil) {
            TileFrame(caption: zoom ? "Zoom" : "Focus") { oneLine, size in
                HStack(spacing: 8 * s) {
                    HoldButton(systemImage: zoom ? "minus.magnifyingglass" : "chevron.left.2",
                               label: zoom ? "Wide" : "Near", enabled: live, speed: -rate, side: min(44 * s, size.height)) { speed in
                        camera.send(zoom ? .driveZoom(speed) : .driveFocus(speed))
                    }
                    // On one line (a short tile) just the two arrows; the bar and distance need the second row.
                    if !oneLine {
                        VStack(spacing: 4 * s) {
                            if let position = drive?.position {
                                PositionBar(fraction: position)
                            }
                            Text(readout(drive))
                                .font(Theme.readout(s))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    HoldButton(systemImage: zoom ? "plus.magnifyingglass" : "chevron.right.2",
                               label: zoom ? "Tele" : "Far", enabled: live, speed: rate, side: min(44 * s, size.height)) { speed in
                        camera.send(zoom ? .driveZoom(speed) : .driveFocus(speed))
                    }
                }
            } accessory: { placement in
                // One pill that steps through the speeds: a segmented control didn't fit a 1-column tile's header. Not
                // on one line, where the arrows take the room (they run at the speed last picked).
                if placement != .inline {
                    PillToggle(title: speed.rawValue, lit: nil, isEnabled: live) { speed = speed.next }
                        .fixedSize()
                        .accessibilityLabel("Speed")
                        .accessibilityValue(speed.rawValue)
                }
            }
        }
    }

    private func readout(_ drive: LensDrive?) -> String {
        if zoom { return camera.state.focalLength.map { "\(Int($0.rounded())) mm" } ?? "Hold to zoom" }
        guard let metres = drive?.distance else { return "Hold to focus" }
        return metres < 10 ? String(format: "%.2f m", metres) : "\(Int(metres.rounded())) m"
    }
}

/// Where a lens motor is, 0 to 1 along a track.
private struct PositionBar: View {
    let fraction: Double
    @Environment(\.tileScale) private var s

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.style.track).frame(height: 4 * s)
                Capsule().fill(Theme.text)
                    .frame(width: 4 * s, height: 12 * s)
                    .offset(x: max(0, min(1, fraction)) * (geo.size.width - 4 * s))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12 * s)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A button that drives for as long as it's held: `drive(speed)` on touch and again every 200 ms, at the speed picked
/// now (a change mid-hold takes at the next renewal), and `drive(0)` once on letting go, or when the touch is canceled,
/// the app leaves the foreground, or the tile goes away.
private struct HoldButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    /// Signed: the sign is the direction.
    let speed: Int
    /// The square it takes: 44 pt, less in a short tile.
    var side: CGFloat = 44
    let drive: (Int) -> Void
    @GestureState private var touching = false
    @State private var renewal: Task<Void, Never>?
    @State private var current = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tileScale) private var s

    var body: some View {
        Image(systemName: systemImage)
            .font(Theme.symbol(min(18 * s, side * 0.45)))
            .frame(width: side, height: side)
            .foregroundStyle(enabled ? Theme.text : Theme.secondaryText.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 8 * s).fill(touching && enabled ? Theme.engaged : Color.clear))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true })
            .onChange(of: touching) { _, now in now && enabled ? start() : stop() }
            .onChange(of: speed, initial: true) { _, new in current = new }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
            .onDisappear { stop() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityHint("Hold to drive")
            .accessibilityAddTraits(.isButton)
    }

    private func start() {
        renewal?.cancel()
        renewal = Task { @MainActor in
            while !Task.isCancelled {
                drive(current)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stop() {
        guard renewal != nil else { return }
        renewal?.cancel()
        renewal = nil
        drive(0)
    }
}

/// Opens the camera's assignable buttons in a window (`AssignableButtonsView`).
struct AssignableTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet

    var body: some View {
        let has = !camera.state.assignableButtons.isEmpty
        Tile(tint: camera.slot.tint, isEnabled: has) {
            Button { presentTileSheet(.assignable(camera.id)) } label: {
                WindowButtonLabel(title: "Assignable")
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable || !has)
        }
    }
}

/// The camera's assignable buttons, each with what it's set to do and its light. Only a function Tiles has checked
/// on a camera can be pressed from here; the rest are listed, grayed.
struct AssignableButtonsView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let controllable = camera.state.connection.isControllable
        NavigationStack {
            Form {
                Section {
                    ForEach(camera.state.assignableButtons) { button in
                        Button { camera.send(.pressAssignable(button.id)) } label: {
                            HStack(spacing: 12) {
                                Text(button.name)
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .frame(minWidth: 40, alignment: .leading)
                                Text(button.function)
                                Spacer(minLength: 8)
                                if let on = button.isOn {
                                    Text(on ? "ON" : "OFF")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(on ? Theme.text : Theme.secondaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(!controllable || !button.isPressable)
                    }
                } footer: {
                    FooterText("A button presses only when it's set to a function Tiles has checked on a camera: "
                               + "S&Q Motion, Base ISO/Sens. and Rec Review so far. Change what a button does on the camera.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Assignable Buttons")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A Sony body's autofocus settings: a button that opens them (`AFSettingsView`), as Assignable's.
struct AFSettingsTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet

    var body: some View {
        let has = camera.state.hasAFSettings
        Tile(tint: camera.slot.tint, isEnabled: has) {
            Button { presentTileSheet(.afSettings(camera.id)) } label: {
                WindowButtonLabel(title: "AF Settings")
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable || !has)
        }
    }
}

/// A Sony body's autofocus settings, as its [Shooting] › [Focus] menu has them: AF / MF, what autofocus looks for and
/// where, how quickly it moves to a new subject and how readily it leaves one, and whether the focus ring takes over.
/// Each grays where the camera won't take a change now (a BURANO's, with the lens it had, all of them).
struct AFSettingsView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = camera.state
        NavigationStack {
            Form {
                if let mode = state.focusMode {
                    Section {
                        Picker("AF / MF", selection: Binding(get: { mode.shown }, set: { camera.send(.setFocusMode($0)) })) {
                            ForEach(mode.options, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!state.connection.isControllable || !mode.isWritable)
                    } header: {
                        Text("AF / MF")
                    }
                }
                if let subject = state.subjectRecognition {
                    Section {
                        picker("Subject Recognition", subject) { .setSubjectRecognition($0) }
                    } footer: {
                        FooterText("What autofocus looks for.")
                    }
                }
                if let area = state.focusArea {
                    Section {
                        picker("Focus Area", area) { .setFocusArea($0) }
                    } footer: {
                        FooterText("Where in the picture it looks. A spot's position is set on the camera.")
                    }
                }
                if state.afTransitionSpeed != nil || state.afSubjectShift != nil {
                    Section {
                        if let speed = state.afTransitionSpeed {
                            picker("Transition Speed", speed, label: { ends($0, of: speed, "Slow", "Fast") }) {
                                .setAFTransitionSpeed($0)
                            }
                        }
                        if let shift = state.afSubjectShift {
                            picker("Subject Shift Sensitivity", shift, label: { ends($0, of: shift, "Locked On", "Responsive") }) {
                                .setAFSubjectShift($0)
                            }
                        }
                    } footer: {
                        FooterText("Transition speed: how quickly focus moves to a new subject. Shift sensitivity: how "
                                   + "readily it leaves the subject it's on for another.")
                    }
                }
                if let assist = state.afAssist {
                    Section {
                        Toggle("AF Assist", isOn: Binding(get: { assist.shown }, set: { camera.send(.setAFAssist($0)) }))
                            .disabled(!state.connection.isControllable || !assist.isWritable)
                    } footer: {
                        FooterText("Turning the focus ring takes over from autofocus while it's turned.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("AF Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func picker<V: Hashable>(_ title: String, _ choice: Choice<V>, label: @escaping (V) -> String = { "\($0)" },
                                     command: @escaping (V) -> CameraCommand) -> some View {
        Picker(title, selection: Binding(get: { choice.shown }, set: { camera.send(command($0)) })) {
            ForEach(choice.options, id: \.self) { Text(label($0)).tag($0) }
        }
        .disabled(!camera.state.connection.isControllable || !choice.isWritable)
    }

    /// "1 (Slow)" and "7 (Fast)" at the ends of a range, the number alone between.
    private func ends(_ value: Int, of choice: Choice<Int>, _ low: String, _ high: String) -> String {
        value == choice.options.first ? "\(value) (\(low))" : value == choice.options.last ? "\(value) (\(high))" : "\(value)"
    }
}
