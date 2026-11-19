import SwiftUI
import CameraCore

// MARK: - Tiles' color picker

/// Tiles' own color picker, in a window from the color it changes: Settings → Appearance's colors and a camera's own
/// color. A grid, a spectrum and sliders, like the system's, and every pick applies as it's made.
///
/// Why not the system's: SwiftUI's `ColorPicker` and `UIColorPickerViewController` draw their contents in a separate
/// system extension (`com.apple.UIKit.ColorPicker.appex`). On some iPads it comes up empty — an empty popover, then
/// an empty sheet — while it works on every simulator and most devices. Why that extension fails on those iPads isn't
/// known. This picker is plain SwiftUI, drawn in the app, so it can't fail that way. It keeps the system's window
/// shape: a popover from the color (a sheet on an iPhone, as the system's was).
struct ColourPickerPanel: View {
    let title: String
    @Binding var rgb: AppearanceSettings.RGB
    var initialMode: Mode = .grid
    /// Outside a popover (the render preview), what the close button does instead.
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case grid = "Grid", spectrum = "Spectrum", sliders = "Sliders"
        var id: Self { self }
    }

    @State private var mode: Mode = .grid
    @State private var hex = ""
    @FocusState private var editingHex: Bool

    static let width: CGFloat = 320
    /// The panel's height, for an iPhone's sheet.
    static let height: CGFloat = 470

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.sheet.text)
                HStack {
                    Spacer()
                    // The presentation's own dismiss, not the binding: a popover in a list row can stay up when
                    // only its binding is set false.
                    Button { if let close { close() } else { dismiss() } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.sheet.secondaryText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("colourPickerClose")
                }
            }
            .frame(height: 32)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch mode {
                case .grid: ColourGrid(rgb: $rgb)
                case .spectrum: ColourSpectrum(rgb: $rgb)
                case .sliders: ColourSliders(rgb: $rgb)
                }
            }
            .frame(height: 220)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(rgb))
                    .frame(width: 56, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.sheet.secondaryText.opacity(0.5), lineWidth: 1))
                    .accessibilityHidden(true)
                Text("Hex")
                    .foregroundStyle(Theme.sheet.secondaryText)
                TextField("RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.sheet.text)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .focused($editingHex)
                    .onSubmit(applyHex)
                    .accessibilityIdentifier("colourPickerHex")
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .onAppear {
            hex = rgb.hex
            mode = initialMode
        }
        // A pick from the grid, the spectrum or the sliders shows in the field, and takes the focus from it: on a Mac
        // the field has the focus from the start, and without this the hex stays on the color the picker opened with.
        // Typing changes `rgb` only when it's submitted, so mid-edit only a pick changes it.
        .onChange(of: rgb) { _, new in
            hex = new.hex
            editingHex = false
        }
        .onChange(of: editingHex) { _, editing in if !editing { applyHex() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("colourPicker")
    }

    private func applyHex() {
        if let typed = AppearanceSettings.RGB(hex: hex) { rgb = typed }
        hex = rgb.hex
    }
}

/// Twelve columns: grays from white to black, then nine rows of twelve hues from dark to light, as the system's grid.
struct ColourGrid: View {
    @Binding var rgb: AppearanceSettings.RGB

    /// Hues across, in degrees: cyan round to green, the system grid's order.
    private static let hues: [Double] = [195, 215, 245, 275, 305, 340, 5, 22, 38, 50, 62, 100]
    static let rows: [[AppearanceSettings.RGB]] = {
        let greys = (0..<12).map { AppearanceSettings.RGB(white: 1 - Double($0) / 11) }
        let colours = (0..<9).map { row -> [AppearanceSettings.RGB] in
            let t = Double(row) / 8
            // Dark and full to bright, then bright and paler.
            let (saturation, brightness) = t <= 0.5 ? (1.0, 0.3 + 1.4 * t) : (1 - 1.5 * (t - 0.5), 1.0)
            return hues.map { AppearanceSettings.RGB(hue: $0 / 360, saturation: saturation, brightness: brightness) }
        }
        return [greys] + colours
    }()

    var body: some View {
        GeometryReader { geo in
            let cell = CGSize(width: geo.size.width / 12, height: geo.size.height / CGFloat(Self.rows.count))
            VStack(spacing: 0) {
                ForEach(Self.rows.indices, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(Self.rows[row].indices, id: \.self) { column in
                            cellView(Self.rows[row][column], size: cell)
                                .accessibilityIdentifier("colourGrid.\(row).\(column)")
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func cellView(_ colour: AppearanceSettings.RGB, size: CGSize) -> some View {
        Button { rgb = colour } label: {
            Rectangle()
                .fill(Color(colour))
                .frame(width: size.width, height: size.height)
                .overlay {
                    if colour.matches(rgb) {
                        Rectangle().strokeBorder(Color.white, lineWidth: 2.5)
                            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("#\(colour.hex)")
    }
}

/// Hue across; white at the top, the full color in the middle, black at the bottom. Drag anywhere.
struct ColourSpectrum: View {
    @Binding var rgb: AppearanceSettings.RGB

    var body: some View {
        GeometryReader { geo in
            let marker = point(for: rgb, in: geo.size)
            ZStack(alignment: .topLeading) {
                // Stops every 30°: HSB is piecewise linear between 60° steps, so these gradients draw exactly what
                // `colour(at:)` picks.
                LinearGradient(colors: stride(from: 0.0, through: 360, by: 30).map {
                    Color(AppearanceSettings.RGB(hue: $0 / 360, saturation: 1, brightness: 1))
                }, startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(0), location: 0.5), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 3)
                    .background(Circle().fill(Color(rgb)))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .frame(width: 26, height: 26)
                    .offset(x: marker.x - 13, y: marker.y - 13)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                rgb = Self.colour(at: drag.location, in: geo.size)
            })
            .accessibilityElement()
            .accessibilityLabel("Spectrum")
            .accessibilityValue("#\(rgb.hex)")
        }
    }

    static func colour(at point: CGPoint, in size: CGSize) -> AppearanceSettings.RGB {
        let x = min(max(point.x / max(size.width, 1), 0), 1)
        let y = min(max(point.y / max(size.height, 1), 0), 1)
        let (saturation, brightness) = y < 0.5 ? (y * 2, 1.0) : (1.0, 1 - (y - 0.5) * 2)
        return AppearanceSettings.RGB(hue: min(x, 0.9999), saturation: saturation, brightness: brightness)
    }

    private func point(for rgb: AppearanceSettings.RGB, in size: CGSize) -> CGPoint {
        let hsb = rgb.hsb
        let y = hsb.brightness < 0.999 ? 0.5 + (1 - hsb.brightness) / 2 : hsb.saturation / 2
        return CGPoint(x: hsb.hue * size.width, y: y * size.height)
    }
}

/// Red, green and blue, each on a track running from none to all of it.
struct ColourSliders: View {
    @Binding var rgb: AppearanceSettings.RGB

    var body: some View {
        VStack(spacing: 16) {
            channel("Red", \.red)
            channel("Green", \.green)
            channel("Blue", \.blue)
        }
        .frame(maxHeight: .infinity)
    }

    private func channel(_ name: String, _ key: WritableKeyPath<AppearanceSettings.RGB, Double>) -> some View {
        var none = rgb, all = rgb
        none[keyPath: key] = 0
        all[keyPath: key] = 1
        let value = Binding(get: { min(1, max(0, rgb[keyPath: key])) }, set: { rgb[keyPath: key] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.sheet.secondaryText)
                Spacer()
                Text("\(Int((value.wrappedValue * 255).rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.sheet.text)
            }
            GradientTrack(name: name, value: value, colours: [Color(none), Color(all)])
        }
    }
}

/// A drag anywhere on the track sets the value, 0 to 1.
private struct GradientTrack: View {
    let name: String
    @Binding var value: Double
    let colours: [Color]

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 28
            let usable = max(geo.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing))
                    .frame(height: knob)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knob - 4, height: knob - 4)
                    .offset(x: 2 + usable * value)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = min(max((drag.location.x - knob / 2) / usable, 0), 1)
            })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue("\(Int((value * 255).rounded()))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 1 / 255)
            case .decrement: value = max(0, value - 1 / 255)
            @unknown default: break
            }
        }
    }
}

/// The picker as a popover shows it, on a dark backdrop, for renders (`DebugScreen.colourPicker`).
struct ColourPickerPreview: View {
    @State private var rgb = AppearanceSettings.RGB(red: 0.98, green: 0.80, blue: 0.10)
    @State private var mode = ProcessInfo.processInfo.environment["CC_SNAPSHOT_PICKER_MODE"] ?? "grid"

    var body: some View {
        ColourPickerPanel(title: "Highlight", rgb: $rgb, initialMode: ColourPickerPanel.Mode(rawValue: mode.capitalized) ?? .grid,
                          close: {})
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Opening it

extension View {
    /// Tiles' color picker (`ColourPickerPanel`) in a window from this view: a popover, which an iPhone shows as a sheet.
    func colourPicker(isPresented: Binding<Bool>, title: String, rgb: Binding<AppearanceSettings.RGB>) -> some View {
        popover(isPresented: isPresented) {
            ColourPickerPanel(title: title, rgb: rgb)
                .presentationDetents([.height(ColourPickerPanel.height), .large])
                .preferredColorScheme(.dark)
        }
    }
}

/// The color well at the end of a color's row: the color, in a ring of colors, as the system's well looks.
struct ColourWell: View {
    let colour: Color

    var body: some View {
        Circle()
            .fill(colour)
            .padding(5)
            .background(Circle().strokeBorder(
                AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center), lineWidth: 3))
            .frame(width: 30, height: 30)
    }
}

/// A row that names a color and shows it in a well: Settings → Appearance's Tiles, Background, Text and Highlight. A tap
/// anywhere on the row opens the picker from the well.
struct ColourRow: View {
    let title: String
    @Binding var rgb: AppearanceSettings.RGB
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.sheet.text)
                Spacer()
                ColourWell(colour: Color(rgb))
                    .colourPicker(isPresented: $picking, title: title, rgb: $rgb)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("#\(rgb.hex)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("colourRow.\(title)")
    }
}
