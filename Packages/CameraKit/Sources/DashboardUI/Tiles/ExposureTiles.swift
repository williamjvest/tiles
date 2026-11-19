import SwiftUI
import CameraCore

// MARK: - Exposure

/// The ND: tap the value for the camera's list. The − + step buttons are an option, switched in edit mode
/// (`PageWidget.stepButtons`; the ND − and ND + tiles are the big ones).
struct NDPresetTile: View {
    let camera: CameraController
    var showsStep = PageWidget.stepByDefault
    @Environment(\.tileScale) private var s

    var body: some View {
        let nd = camera.state.nd
        let live = camera.state.connection.isControllable && nd?.preset.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: nd != nil) {
            if showsStep {
                TileFrame(caption: "ND", switchCaption: "Step", trailingFrom: WidgetKind.ndPreset.spec.trailingFrom, valueWins: true) { oneLine, size in
                    value(nd: nd, live: live, oneLine: oneLine, size: size)
                } accessory: { placement in
                    HStack(spacing: (placement.isSmall ? 6 : 10) * s) {
                        AutoPill(choice: camera.state.ndAuto, isEnabled: camera.state.connection.isControllable,
                                 height: placement.isSmall ? 20 : 34) {
                            camera.send(.setNDAuto($0))
                        }
                        RoundIconButton(systemName: "minus", isEnabled: live, diameter: placement.isSmall ? 20 : 34) { step(-1) }
                            .accessibilityLabel("ND down")
                            .accessibilityIdentifier("ndStepDown")
                        RoundIconButton(systemName: "plus", isEnabled: live, diameter: placement.isSmall ? 20 : 34) { step(1) }
                            .accessibilityLabel("ND up")
                            .accessibilityIdentifier("ndStepUp")
                    }
                }
            } else if camera.state.ndAuto != nil {
                // An FX6's Auto ND, in the header.
                TileFrame(caption: "ND", valueWins: true) { oneLine, size in
                    value(nd: nd, live: live, oneLine: oneLine, size: size)
                } accessory: { _ in
                    AutoPill(choice: camera.state.ndAuto, isEnabled: camera.state.connection.isControllable) {
                        camera.send(.setNDAuto($0))
                    }
                }
            } else {
                TileFrame(caption: "ND", valueWins: true) { oneLine, size in
                    value(nd: nd, live: live, oneLine: oneLine, size: size)
                }
            }
        }
    }

    private func value(nd: NDState?, live: Bool, oneLine: Bool, size: CGSize) -> some View {
        PickerValue(text: nd?.preset.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 34, scale: s),
                    options: nd?.preset.options ?? [], title: { $0 }, isLive: live) {
            camera.send(.setNDPreset($0))
        }
    }

    private func step(_ delta: Int) {
        if let next = camera.state.nd?.preset.option(offsetBy: delta) {
            camera.send(.setNDPreset(next))
        }
    }
}

struct NDStepTile: View {
    let camera: CameraController
    let delta: Int
    @Environment(\.tileScale) private var s

    var body: some View {
        let nd = camera.state.nd
        Tile(tint: camera.slot.tint, isEnabled: nd != nil) {
            Button {
                if let next = camera.state.nd?.preset.option(offsetBy: delta) {
                    camera.send(.setNDPreset(next))
                }
            } label: {
                GeometryReader { geo in
                    let glyph = Image(systemName: delta < 0 ? "minus" : "plus").foregroundStyle(Theme.text)
                    if geo.size.height < (2 * Theme.insetV + Theme.captionRow + 6) * s {
                        // Too short for the caption row: caption and glyph on one line, centered.
                        HStack(spacing: 8 * s) {
                            Caption("ND").environment(\.captionPlacement, .line)
                                .environment(\.shortLine, geo.size.height < Theme.captionLine(s))
                            glyph.font(Theme.symbol(min(18 * s, max(geo.size.height - 2 * s, 8 * s)), weight: .regular))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        glyph
                            .font(Theme.symbol(24 * s, weight: .regular))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) {
                                // The glyph says which way; the caption only what it steps.
                                CaptionRow("ND")
                                    .padding(.horizontal, Theme.inset * s)
                                    .padding(.top, Theme.insetV * s)
                            }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable)
        }
    }
}

/// Angle | Speed, for a camera that reports its shutter mode.
private struct ShutterModeSwitch: View {
    let camera: CameraController
    var placement: SwitchPlacement

    var body: some View {
        let mode = camera.state.shutterMode
        ModeSwitch(options: ShutterMode.allCases, selection: mode?.shown,
                   full: { $0 == .angle ? "Angle" : "Speed" }, short: { $0 == .angle ? "Ang" : "Spd" },
                   placement: placement, isEnabled: camera.state.connection.isControllable && mode?.isWritable == true) {
            camera.send(.setShutterMode($0))
        }
    }
}

/// The shutter dial. Where no shutter value tile carries the Angle | Speed switch (`showsMode`, the iPhone column),
/// the dial gets the same header as every other tile: "SHUTTER" with the switch beside it.
struct ShutterTile: View {
    let camera: CameraController
    var showsMode = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let mode = camera.state.shutterMode
        let useAngle = (mode?.shown ?? .angle) == .angle
        let angle = camera.state.shutterAngle
        let speed = camera.state.shutterSpeed
        let frameRate = camera.state.frameRate
        let controllable = camera.state.connection.isControllable
        // Compute the needle angle from the shutter value, clockwise from 12 o'clock.
        // 180° = straight down (a 180° angle). nil = no value known → no needle drawn.
        let needle: Double? = {
            if useAngle {
                guard let deg = angle?.shown, deg > 0, deg <= 360 else { return nil }
                // Shutter angle: 360° maps to full circle (back at top). 180° → 180°.
                return deg
            } else {
                // Speed mode: convert "1/N" to equivalent angle at the current frame rate.
                // angle = 360 × frameRate × (1/N)
                guard let shown = speed?.shown else { return nil }
                let fps: Double
                if let variable = frameRate?.variable?.shown, variable == true,
                   let variableRate = frameRate?.variableRate?.shown {
                    fps = variableRate
                } else if let project = frameRate?.project.shown, let d = Double(project) {
                    fps = d
                } else {
                    // No frame rate known — omit the needle
                    return nil
                }
                // Parse "1/48" → 1/48 seconds
                let parts = shown.split(separator: "/")
                if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                    let deg = 360 * fps * (num / den)
                    return deg.truncatingRemainder(dividingBy: 360)
                }
                // Whole-number speed (e.g. "1" second)
                if let secs = Double(shown) {
                    return (360 * fps * secs).truncatingRemainder(dividingBy: 360)
                }
                return nil
            }
        }()
        Tile(tint: camera.slot.tint, isEnabled: useAngle ? angle != nil : speed != nil) {
            let dial = Group {
                if useAngle {
                    ChoiceMenu(options: angle?.options ?? [], title: Format.angle,
                               isEnabled: controllable && angle?.isWritable == true, current: angle?.shown,
                               onSelect: { camera.send(.setShutterAngle($0)) }) { live in
                        ShutterDial(text: angle.map { Format.angle($0.shown) } ?? "—", live: live, needleAngle: needle)
                            .contentShape(Rectangle())
                    }
                } else {
                    ChoiceMenu(options: speed?.options ?? [], title: { $0 },
                               isEnabled: controllable && speed?.isWritable == true, current: speed?.shown,
                               onSelect: { camera.send(.setShutterSpeed($0)) }) { live in
                        ShutterDial(text: speed?.shown ?? "—", live: live, needleAngle: needle)
                            .contentShape(Rectangle())
                    }
                }
            }
            .environment(\.tileCaption, "Shutter")
            GeometryReader { geo in
                // Under ~90pt a dial is a speck (the gallery showed a 10pt dial in a 66pt row): show the shutter as a
                // value instead, the same face as the shutter value tile. So too with ECS on: the shutter is its
                // frequency then, and the angle the dial would show isn't in use.
                if geo.size.height < 90 * s || camera.state.ecs?.on.shown == true {
                    ShutterValueFace(camera: camera, showsMode: showsMode)
                } else if showsMode && mode != nil {
                    TileFrame(caption: "Shutter") { _, _ in
                        // The header switch overhangs the caption line; keep the dial clear of it.
                        dial.padding(.top, 8 * s).padding(.bottom, 2 * s)
                    } accessory: { _ in
                        ShutterModeSwitch(camera: camera, placement: .header)
                    }
                } else {
                    dial.padding(Theme.inset * s)
                }
            }
        }
    }
}

/// The shutter dial. Draws a clock-face with tick marks and a blue needle.
/// The needle angle is computed from the current shutter value and passed in:
/// `needleAngle` in degrees clockwise from 12 o'clock (0° = top, 180° = bottom).
/// nil means the value isn't known; no needle is drawn rather than a wrong one.
struct ShutterDial: View {
    var text: String
    var live = true
    /// Clockwise degrees from 12 o'clock. nil → omit the needle entirely.
    var needleAngle: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(Theme.style.dialRing, lineWidth: 1.5)
                ForEach(0..<12, id: \.self) { index in
                    Capsule()
                        .fill(Theme.style.dialTick.opacity(index % 3 == 0 ? 1 : 0.7))
                        .frame(width: 1.5, height: index % 3 == 0 ? 7 : 4)
                        .offset(y: -diameter / 2 + 8)
                        .rotationEffect(.degrees(Double(index) * 30))
                }
                if let angle = needleAngle {
                    Capsule()
                        .fill(Theme.needle)
                        .frame(width: 2.5, height: 12)
                        .offset(y: -diameter / 2 + 9)
                        .rotationEffect(.degrees(angle))
                }
                Text(text)
                    .font(Theme.value(diameter * 0.2))
                    .foregroundStyle(live ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, diameter * 0.12)
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The shutter as a value (the wide layouts put this beside the dial), with the Angle | Speed switch.
struct ShutterValueTile: View {
    let camera: CameraController

    var body: some View {
        let useAngle = (camera.state.shutterMode?.shown ?? .angle) == .angle
        Tile(tint: camera.slot.tint,
             isEnabled: useAngle ? camera.state.shutterAngle != nil : camera.state.shutterSpeed != nil) {
            ShutterValueFace(camera: camera, showsMode: true)
        }
    }
}

/// Caption, the shutter value as a picker, and (with `showsMode`) the Angle | Speed switch. Shared by the shutter
/// value tile and a dial tile too short for its dial.
struct ShutterValueFace: View {
    let camera: CameraController
    var showsMode: Bool
    @Environment(\.tileScale) private var s

    var body: some View {
        let useAngle = (camera.state.shutterMode?.shown ?? .angle) == .angle
        let angle = camera.state.shutterAngle
        let speed = camera.state.shutterSpeed
        let controllable = camera.state.connection.isControllable
        let hasMode = showsMode && camera.state.shutterMode != nil
        let spec = WidgetKind.shutterValue.spec
        TileFrame(caption: "Shutter", switchCaption: hasMode ? "Mode" : nil,
                  trailingFrom: spec.trailingFrom, footerFrom: spec.footerFrom, valueWins: true) { oneLine, size in
            let font = Theme.valueSize(oneLine: oneLine, height: size.height, max: 44, scale: s)
            if let ecs = camera.state.ecs, ecs.on.shown {
                // ECS on (an FX6's): the shutter runs at its frequency, set on the ECS tile, so nothing to pick here.
                ValueLine(text: "ECS " + (ecs.frequency.map(Format.hertz) ?? "—"), size: font, showsChevron: false,
                          color: Theme.secondaryText)
            } else if useAngle {
                PickerValue(text: angle.map { Format.angle($0.shown) } ?? "—", size: font,
                            options: angle?.options ?? [], title: Format.angle,
                            isLive: controllable && angle?.isWritable == true) { camera.send(.setShutterAngle($0)) }
            } else {
                PickerValue(text: speed?.shown ?? "—", size: font, options: speed?.options ?? [], title: { $0 },
                            isLive: controllable && speed?.isWritable == true) { camera.send(.setShutterSpeed($0)) }
            }
        } accessory: { placement in
            if hasMode {
                ShutterModeSwitch(camera: camera, placement: placement)
            }
        }
    }
}

struct FrameRateTile: View {
    let camera: CameraController
    /// The cameras a frame rate set here goes to as well, on a page that links it (`DashboardStore.linkedPeers`).
    var linkedPeers: [CameraController] = []

    @State private var pendingRate: String? = nil
    /// The letters of the cameras `pendingRate` restarts: this one, and any linked camera it restarts (a VENICE's
    /// project rate restarts its image, and a linked page sends it there without that camera's own tile asking).
    @State private var restarting: [String] = []
    @Environment(\.tileScale) private var s

    var body: some View {
        let rate = camera.state.frameRate
        let controllable = camera.state.connection.isControllable
        // Off-speed on: the sensor's rate is the value, the project rate rides after it.
        let offSpeed = rate?.variable?.shown == true ? rate?.variableRate : nil
        Tile(tint: camera.slot.tint, isEnabled: rate != nil) {
            // trailingFrom / footerFrom match ShutterValueTile (via spec) so the Fixed | Variable switch gets its
            // own column at the same widths as Shutter's Mode switch.
            let fpsSpec = WidgetKind.frameRate.spec
            TileFrame(caption: "FPS", switchCaption: rate?.variable == nil ? nil : rate?.variableName,
                      trailingFrom: fpsSpec.trailingFrom, footerFrom: fpsSpec.footerFrom, valueWins: true) { oneLine, size in
                if let offSpeed {
                    PickerValue(text: Self.fps(offSpeed.shown), size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 72, scale: s),
                                options: offSpeed.options, title: Self.fps,
                                isLive: controllable && offSpeed.isWritable,
                                detail: rate.map { "→ \($0.project.shown)" }) { camera.send(.setFrameRateVariableRate($0)) }
                } else {
                    PickerValue(text: rate?.project.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 72, scale: s),
                                options: rate?.project.options ?? [], title: { $0 },
                                isLive: controllable && rate?.project.isWritable == true) { picked in
                        // A rate that restarts this camera, or one linked to it, is confirmed first.
                        let restarts = ([camera] + linkedPeers).filter {
                            $0.state.frameRate?.project.restartRequired.contains(picked) == true
                        }
                        if restarts.isEmpty {
                            camera.send(.setFrameRate(picked))
                        } else {
                            restarting = restarts.map(\.slot.label).sorted()
                            pendingRate = picked
                        }
                    }
                }
            } accessory: { placement in
                // Fixed | Variable only for a camera that reports S&Q on/off (the FX3 doesn't).
                if let variable = rate?.variable {
                    // The same switch as Shutter's Mode, at the same sizes (`ModeSwitch`).
                    ModeSwitch(options: [false, true], selection: variable.shown,
                               full: { $0 ? "Variable" : "Fixed" }, short: { $0 ? "Var" : "Fixed" },
                               placement: placement, isEnabled: controllable && variable.isWritable) {
                        camera.send(.setFrameRateVariable($0))
                    }
                }
            }
        }
        .confirmationDialog(
            pendingRate.map { "Switch to \($0)?" } ?? "",
            isPresented: Binding(get: { pendingRate != nil }, set: { if !$0 { pendingRate = nil } }),
            titleVisibility: .visible
        ) {
            if let rate = pendingRate {
                Button("Switch to \(rate) (restarts \(restartingOnlyThis ? "camera" : Self.cameras(restarting)))") {
                    camera.send(.setFrameRate(rate))
                    pendingRate = nil
                }
                Button("Cancel", role: .cancel) { pendingRate = nil }
            }
        } message: {
            Text(restartingOnlyThis ? "The camera will restart to apply this frame rate."
                 : "\(Self.cameras(restarting, capitalized: true)) will restart to apply this frame rate: the page links it.")
        }
    }

    private var restartingOnlyThis: Bool { restarting == [camera.slot.label] }

    /// "camera B", "cameras A and B", "cameras A, B and C" (or "Camera B"…).
    static func cameras(_ labels: [String], capitalized: Bool = false) -> String {
        let word = capitalized ? "Camera" : "camera"
        guard labels.count > 1, let last = labels.last else { return "\(word) \(labels.first ?? "")" }
        return "\(word)s \(labels.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// 60 → "60", 23.976 → "23.98".
    static func fps(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.2f", rate)
    }
}

struct ISOTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        if camera.state.iso == nil, let gain = camera.state.gain {
            gainTile(gain)
        } else {
            isoTile
        }
    }

    /// The base switch (ISO, or the base sensitivity, Low | High where an FX6 works in dB and Low | Mid | High on an
    /// FX5 in Custom), and after it the AGC (Auto) of an FX6 or FX5, which no other camera has. In the switches' column or
    /// bottom row, full size: Auto beside the switch there, under the same "BASE", or dropped from a bottom row too
    /// narrow for both. In the header and on one line the "BASE" caption gives way first, then the switch becomes one
    /// chip with the base, which flips it (as `ModeSwitch` does), and only then Auto.
    @ViewBuilder
    private func baseSwitch<Base: Hashable>(_ base: Choice<Base>, title: @escaping (Base) -> String,
                                            set: @escaping (Base) -> Void, placement: SwitchPlacement,
                                            controllable: Bool) -> some View {
        let live = controllable && base.isWritable
        let switcher = { (small: Bool) in
            MiniSegmented(options: base.options, selection: base.shown, label: title, isEnabled: live, small: small) {
                set($0)
            }
        }
        // The next base, round: an FX5 has three.
        let chip = PillToggle(title: title(base.shown), lit: nil, isEnabled: live) {
            let i = base.options.firstIndex(of: base.shown).map { $0 + 1 } ?? 0
            if base.options.count > 1 { set(base.options[i % base.options.count]) }
        }
        .fixedSize()
        let auto = { (height: CGFloat) in
            AutoPill(choice: camera.state.isoAuto, isEnabled: controllable, height: height) { camera.send(.setISOAuto($0)) }
        }
        // Auto draws nothing on a camera without AGC, so these are the base switch alone there.
        switch placement {
        case .trailing:
            // Its own column, full size: larger targets on a phone. 66 pt a base: an FX5's three (800 | 4000 | 12800)
            // cut the last short at 132.
            HStack(spacing: 8 * s) {
                switcher(false).frame(width: CGFloat(max(2, base.options.count)) * 66 * s)
                auto(34)
            }
        case .footer:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8 * s) {
                    switcher(false)
                    auto(34)
                }
                switcher(false)
            }
        default:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5 * s) {
                    Caption("Base")
                    switcher(true)
                    auto(20)
                }
                HStack(spacing: 5 * s) {
                    switcher(true)
                    auto(20)
                }
                HStack(spacing: 5 * s) {
                    chip
                    auto(20)
                }
                chip
            }
        }
    }

    /// Gain in dB, where the camera works in dB rather than ISO (an FX6 in Custom).
    private func gainTile(_ gain: Choice<Int>) -> some View {
        let controllable = camera.state.connection.isControllable
        let live = controllable && gain.isWritable
        let isoSpec = WidgetKind.iso.spec
        return Tile(tint: camera.slot.tint, isEnabled: true) {
            TileFrame(caption: "Gain", switchCaption: camera.state.baseSensitivity == nil ? nil : "Base",
                      trailingFrom: isoSpec.trailingFrom, footerFrom: isoSpec.footerFrom, valueWins: true) { oneLine, size in
                PickerValue(text: "\(gain.shown) dB", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 72, scale: s),
                            options: gain.options, title: { "\($0) dB" }, isLive: live) {
                    camera.send(.setGain($0))
                }
            } accessory: { placement in
                if let base = camera.state.baseSensitivity {
                    baseSwitch(base, title: { $0 }, set: { camera.send(.setBaseSensitivity($0)) }, placement: placement,
                               controllable: controllable)
                } else {
                    AutoPill(choice: camera.state.isoAuto, isEnabled: controllable) { camera.send(.setISOAuto($0)) }
                }
            }
        }
    }

    private var isoTile: some View {
        let iso = camera.state.iso
        let controllable = camera.state.connection.isControllable
        return Tile(tint: camera.slot.tint, isEnabled: iso != nil) {
            let isoSpec = WidgetKind.iso.spec
            // ARRI calls it EI (Exposure Index), on the camera and in its Web Remote.
            TileFrame(caption: camera.state.make == .arri ? "EI" : "ISO",
                      switchCaption: camera.state.baseISO == nil && camera.state.baseSensitivity == nil ? nil : "Base",
                      trailingFrom: isoSpec.trailingFrom, footerFrom: isoSpec.footerFrom, valueWins: true) { oneLine, size in
                // The sensor's native ISO, where the maker states it, is marked: "800 (base)" in the menu, BASE beside it.
                let native = camera.state.nativeISOs
                PickerValue(text: iso.map { String($0.shown) } ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 72, scale: s),
                            options: iso?.options ?? [], title: { native.contains($0) ? "\($0) (base)" : String($0) },
                            isLive: controllable && iso?.isWritable == true,
                            detail: iso.flatMap { native.contains($0.shown) ? "base" : nil }, detailIsCaption: true) {
                    camera.send(.setISO($0))
                }
            } accessory: { placement in
                if let base = camera.state.baseISO {
                    baseSwitch(base, title: { String($0) }, set: { camera.send(.setBaseISO($0)) }, placement: placement,
                               controllable: controllable)
                } else if let base = camera.state.baseSensitivity {
                    // An FX5 in Custom works in ISO, on Custom's base sensitivity (an FX6's works in dB: the Gain tile).
                    baseSwitch(base, title: { $0 }, set: { camera.send(.setBaseSensitivity($0)) }, placement: placement,
                               controllable: controllable)
                } else {
                    AutoPill(choice: camera.state.isoAuto, isEnabled: controllable) { camera.send(.setISOAuto($0)) }
                }
            }
        }
    }
}

struct WhiteBalancePresetTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let wb = camera.state.whiteBalance
        let live = camera.state.connection.isControllable && wb?.preset.isWritable == true
        // A Kelvin preset shows the Kelvin, following the slider; any other mode (Auto, or a Sony mode Tiles can't
        // set) shows as itself.
        let text = wb.map { $0.preset.isWritable && $0.preset.shown.hasSuffix("K") ? "\(Int($0.kelvin.shown))K" : $0.preset.shown } ?? "—"
        Tile(tint: camera.slot.tint, isEnabled: wb != nil) {
            TileFrame(caption: "WB", valueWins: true) { oneLine, size in
                PickerValue(text: text, size: Theme.valueSize(oneLine: oneLine, height: size.height, max: 48, scale: s),
                            options: wb?.preset.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine) {
                    camera.send(.setWhiteBalancePreset($0))
                }
            }
        }
    }
}

struct WhiteBalanceSlidersTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    /// Tracks show what the setting does to the picture, as Lightroom and Resolve do: higher Kelvin → warmer image,
    /// so the track runs blue → orange. Tint runs green → magenta (see StateMapper).
    private static let kelvinStops = [Color(red: 0.2, green: 0.45, blue: 1.0), Color(red: 0.6, green: 0.78, blue: 1.0), .white,
                                      Color(red: 1.0, green: 0.88, blue: 0.7), Color(red: 1.0, green: 0.55, blue: 0.15)]
    /// Reset target for the temperature slider's double-tap gesture (daylight white balance).
    static let daylightKelvin = 5600.0

    private static let tintStops = [Color(red: 0.2, green: 0.8, blue: 0.3), .white, Color(red: 0.9, green: 0.3, blue: 0.75)]

    /// A track's colors as they read on the tile (`Theme.legible`): on a light tile (custom colors) the white middle
    /// and the pale stops either side vanish into the tile, so each goes toward the text until it stands out.
    /// Untouched with the standard colors.
    private static func track(_ stops: [Color]) -> AnyShapeStyle {
        AnyShapeStyle(LinearGradient(colors: stops.map(Theme.legible), startPoint: .leading, endPoint: .trailing))
    }

    var body: some View {
        let wb = camera.state.whiteBalance
        let controllable = camera.state.connection.isControllable
        let tempLive = controllable && wb?.kelvin.isWritable == true
        let tintLive = controllable && wb?.tint?.isWritable == true
        // Tint only for a camera that reports it; with no camera yet, keep the shape.
        let showsTint = wb == nil || wb?.tint != nil
        Tile(tint: camera.slot.tint, isEnabled: wb != nil) {
            GeometryReader { geo in
                // With Text Size's bigger type the caption rows are taller, so the tile is that much smaller for its
                // sliders: where Tint doesn't fit it goes, as in a small tile. Keeping the standard type to keep
                // it would put its caption row out of line with the page.
                let form = Self.form(for: geo.size, showsTint: showsTint, scale: s)
                let temp = SliderRow(caption: "Temp", readout: wb.map { "\(Int($0.kelvin.shown))K" } ?? "—",
                                     live: tempLive, stacked: form.stacked, line: form.line) {
                    TrackSlider(
                        fraction: wb?.kelvin.fraction ?? 0.5,
                        track: Self.track(Self.kelvinStops),
                        marks: wb.map { [$0.kelvin.fraction(for: Self.daylightKelvin)] } ?? [],
                        resetFraction: wb?.kelvin.fraction(for: Self.daylightKelvin),
                        stepFraction: wb?.kelvin.stepFraction,
                        isEnabled: tempLive
                    ) { fraction in
                        if let kelvin = camera.state.whiteBalance?.kelvin {
                            camera.send(.setKelvin(kelvin.value(atFraction: fraction)))
                        }
                    }
                }
                let tintRow = SliderRow(caption: "Tint", readout: wb?.tint.map { Format.tint($0.shown) } ?? "—",
                                        live: tintLive, stacked: form.stacked, line: form.line) {
                    TrackSlider(
                        fraction: wb?.tint?.fraction ?? 0.5,
                        track: Self.track(Self.tintStops),
                        marks: wb?.tint.map { [$0.fraction(for: 0)] } ?? [],
                        resetFraction: wb?.tint?.fraction(for: 0),
                        stepFraction: wb?.tint?.stepFraction,
                        isEnabled: tintLive
                    ) { fraction in
                        if let tint = camera.state.whiteBalance?.tint {
                            camera.send(.setTint(tint.value(atFraction: fraction)))
                        }
                    }
                }
                Group {
                    if form.sideBySide {
                        HStack(spacing: 16 * s) { temp; tintRow }
                    } else {
                        VStack(spacing: (form.stacked ? Self.stackGap : Self.lineGap) * s) {
                            temp
                            if form.tint { tintRow }
                        }
                    }
                }
                .padding(.horizontal, Theme.inset * s)
                .padding(.vertical, Theme.insetV * s)
                // From the top: in a narrow column too short for two stacked rows (a phone's 2-wide column for a camera
                // without AF/MF: VENICE, ALEXA, FX6), centering the overflow lifts the caption row above every other tile's.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
    }

    // MARK: Forms

    /// How the tile lays out its sliders: caption over track (`stacked`) or caption, track and readout on one line, each
    /// line `line` tall; one under the other, or `sideBySide`; with Tint, or without it (`tint` false). `squeezed`: stacked
    /// in a narrow tile on tracks shorter than `trackMinimum`, which beats losing Tint.
    struct Form: Equatable {
        var stacked: Bool
        var tint: Bool
        var sideBySide = false
        var squeezed = false
        var line: CGFloat = sliderLine
    }

    /// A slider's track at its smallest that still takes a thumb: the knob's 20 pt.
    static let trackMinimum: CGFloat = 20
    /// Stacked in a narrow tile, the shortest a track gets before Tint goes: below this both rows fit but Tint
    /// would be cut off.
    static let squeezedTrack: CGFloat = 14
    static let stackGap: CGFloat = 4
    static let lineGap: CGFloat = 2
    /// Below this width one-line rows leave too little track (a phone's half column): rows stay stacked.
    static let oneLineFrom: CGFloat = 220
    /// From this width a short tile can put Temp and Tint side by side, each with a usable track.
    static let sideBySideFrom: CGFloat = 440

    /// The form for a tile of `size` at Dynamic Text Size scale `s`: the standard tile's at `size` over `s`, its lines
    /// `s` times as tall.
    static func form(for size: CGSize, showsTint: Bool, scale s: CGFloat) -> Form {
        guard s != 1 else { return form(for: size, showsTint: showsTint) }
        var form = form(for: CGSize(width: size.width / s, height: size.height / s), showsTint: showsTint)
        form.line *= s
        return form
    }

    /// The richest form that fits `size`, never one that's cut off. In order: both stacked; both on one
    /// line each; side by side; then Temp alone, stacked or on one line. Temp alone at its smallest is the last resort.
    /// Its caption rows are Text Size's (`Theme.captionRow`).
    static func form(for size: CGSize, showsTint: Bool) -> Form {
        let room = size.height - 2 * Theme.insetV
        let captionRow = Theme.captionRow
        let stackedRow = captionRow + 2 + trackMinimum
        let wide = size.width >= oneLineFrom
        if showsTint {
            if room >= 2 * stackedRow + stackGap { return Form(stacked: true, tint: true) }
            if wide, room >= 2 * trackMinimum + lineGap {
                return Form(stacked: false, tint: true, line: min(sliderLine, (room - lineGap) / 2))
            }
            if size.width >= sideBySideFrom, room >= trackMinimum {
                return Form(stacked: false, tint: true, sideBySide: true, line: min(sliderLine, room))
            }
            // Narrow, where one line each can't go: both rows on shorter tracks while they fit.
            if !wide, room >= 2 * (captionRow + 2 + squeezedTrack) + stackGap {
                return Form(stacked: true, tint: true, squeezed: true)
            }
        }
        if room >= stackedRow || !wide { return Form(stacked: true, tint: false) }
        return Form(stacked: false, tint: false, line: max(12, min(sliderLine, room)))
    }
}

/// One slider with its caption and readout: the caption row over the track, which fills the space below it, or
/// caption, track and readout on one line when the tile is short. Rows share a tile equally, like small tiles.
/// A one-line slider row's height, and its knob's: the White Balance tile's rows (`SliderRow`).
let sliderLine: CGFloat = 20

struct SliderRow<Slider: View>: View {
    var caption: String
    var readout: String
    var live: Bool
    var stacked: Bool
    /// A one-line row's height, which its knob takes (`TrackSlider`): 20 pt, less in a tile too short for its rows.
    var line: CGFloat = sliderLine
    @ViewBuilder var slider: () -> Slider
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        let short = shortLine || !stacked && line < Theme.captionLine(s)
        let value = Text(verbatim: readout)
            .font(Theme.readout(Theme.textScale(s, shortLine: short)))
            .foregroundStyle(live ? Theme.text : Theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2 * s) {
                    CaptionRow(caption) { value }
                    slider().frame(minHeight: 12 * s, maxHeight: .infinity)
                }
            } else {
                // Fixed caption and readout widths, so stacked tracks start and end together: at the type's own size, as
                // Text Size draws it. At the tile's scale alone, a big Text Size cut "TEMP" to "TE…" beside a whole
                // "TINT", and the tracks end apart.
                let type = Theme.textScale(s, shortLine: short) * Theme.textBump
                HStack(spacing: 8 * s) {
                    Caption(caption).frame(width: 34 * type, alignment: .leading).environment(\.captionPlacement, .line)
                        .environment(\.shortLine, short)
                    slider().frame(height: line)
                    value.frame(minWidth: 46 * type, alignment: .trailing)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Iris fader. It steps through the f-numbers the camera offers for the mounted lens, third stops, with full stops
/// marked; tap the f-number for the list.
struct IrisFaderTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    private static let fullStops: Set<Double> = [1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22, 32]

    /// The longest of `labels`, the ones that set the readout's width (digits are tabular, so one of each length).
    static func widest(_ labels: [String]) -> [String] {
        let longest = labels.map(\.count).max() ?? 0
        return Array(Set(labels.filter { $0.count == longest })).sorted()
    }

    var body: some View {
        let iris = camera.state.iris
        let live = camera.state.connection.isControllable && iris?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: iris != nil) {
            GeometryReader { geo in
                let options = iris?.options ?? []
                let index = iris.flatMap { options.firstIndex(of: $0.shown) } ?? 0
                let slider = TrackSlider(
                    fraction: options.count > 1 ? Double(index) / Double(options.count - 1) : 0.5,
                    track: AnyShapeStyle(Theme.style.track),
                    marks: options.count > 1
                        ? options.enumerated().filter { Self.fullStops.contains($0.element) }.map { Double($0.offset) / Double(options.count - 1) }
                        : [],
                    stepFraction: options.count > 1 ? 1 / Double(options.count - 1) : nil,
                    isEnabled: live && options.count > 1
                ) { fraction in
                    guard options.count > 1 else { return }
                    let picked = options[Int((fraction * Double(options.count - 1)).rounded())]
                    camera.send(.setIris(picked))
                }
                let twoRows = (2 * Theme.insetV + Theme.captionRow + 4 + 24) * s
                let short = geo.size.height < twoRows && geo.size.height < Theme.captionLine(s)
                let type = Theme.textScale(s, shortLine: short)
                let readout = ChoiceMenu(options: options, title: Format.fNumber, isEnabled: live, current: iris?.shown,
                                         onSelect: {
                    camera.send(.setIris($0))
                }) { menuLive in
                    HStack(spacing: 4 * s) {
                        // As wide as the lens's widest f-number, so the track keeps its length as the iris moves
                        // (without this, the slider grows and shrinks between "f/2.8" and "f/11").
                        ZStack(alignment: .trailing) {
                            ForEach(Self.widest(options.map(Format.fNumber)), id: \.self) { label in
                                Text(label).font(Theme.readout(type)).lineLimit(1).fixedSize().hidden()
                            }
                            Text(iris.map { Format.fNumber($0.shown) } ?? "—")
                                .font(Theme.readout(type))
                                .foregroundStyle(menuLive ? Theme.text : Theme.secondaryText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if menuLive { Chevron() }
                    }
                    .contentShape(Rectangle())
                }
                // Two rows need the caption row and a full 24pt knob between the insets (56pt). Shorter (an iPhone row is
                // ~48pt) goes to one line, centered: otherwise the knob touches the bottom edge.
                Group {
                    if geo.size.height < twoRows {
                        HStack(spacing: 8 * s) {
                            Caption("Iris").environment(\.captionPlacement, .line).environment(\.shortLine, short)
                            // No taller than the line: a 22 pt row (a small phone) cut the knob off top and bottom.
                            slider.frame(height: min(24 * s, geo.size.height))
                            // A line shorter than a small control drops Auto rather than cut it off, as TileFrame does.
                            if geo.size.height >= Theme.smallControl * s {
                                autoSwitch
                            }
                            readout
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4 * s) {
                            CaptionRow("Iris") {
                                HStack(spacing: 8 * s) {
                                    autoSwitch
                                    readout
                                }
                            }
                            slider.frame(minHeight: 22 * s, maxHeight: .infinity)
                        }
                        .padding(.vertical, Theme.insetV * s)
                    }
                }
                // Names the f-number's menu, as `TileFrame` names other tiles' (it was a button with no name).
                .environment(\.tileCaption, "Iris")
                .padding(.horizontal, Theme.inset * s)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Auto | the f-number, where the camera can set the iris itself (an FX6's Iris Mode): lit while it does, and the
    /// f-number reads but doesn't set meanwhile. Absent elsewhere, so other cameras' tiles are as they were.
    private var autoSwitch: some View {
        AutoPill(choice: camera.state.irisAuto, isEnabled: camera.state.connection.isControllable) {
            camera.send(.setIrisAuto($0))
        }
    }
}

/// "Auto", lit while the camera sets a value itself (an FX6's Auto ND, AGC): nothing at all where the camera has no
/// such switch, so other cameras' tiles are as they were.
struct AutoPill: View {
    let choice: Choice<Bool>?
    let isEnabled: Bool
    /// `PillToggle.height`: 20 in a header or on one line, 34 beside full-size switches.
    var height: CGFloat = 20
    let set: (Bool) -> Void

    var body: some View {
        if let choice {
            PillToggle(title: "Auto", lit: choice.shown, isEnabled: isEnabled && choice.isWritable, height: height) {
                set(!choice.shown)
            }
            // Its own width; its height gives way to a short line, down to a small control's.
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityValue(choice.shown ? "On" : "Off")
        }
    }
}
