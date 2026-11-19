import SwiftUI
import CameraCore

/// Settings → Appearance: the page's colors and its tiles' corners (`AppearanceSettings`).
/// A change shows at once, on the preview here and on the page behind the sheet. The sheet itself keeps the standard
/// look (`Theme.sheet`).
struct AppearanceView: View {
    @Bindable private var theme = ThemeStore.shared

    var body: some View {
        Form {
            Section {
                AppearancePreview()
                    .listRowInsets(EdgeInsets())
            } footer: {
                FooterText("Camera A's tiles as the page draws them: a value, a switch that's on, the Lock tile locked, and REC.")
            }
            Section {
                Toggle("Custom Colors", isOn: $theme.appearance.customColors)
                if theme.appearance.customColors {
                    ColourRow(title: "Tiles", rgb: colour(\.tile))
                    ColourRow(title: "Background", rgb: colour(\.background))
                    ColourRow(title: "Text", rgb: colour(\.text))
                    ColourRow(title: "Highlight", rgb: colour(\.highlight))
                    Button("Reset Colors", action: resetColours)
                        .disabled(isDaylight)
                }
            } header: {
                Text("Colors")
            } footer: {
                FooterText("They start on white tiles with black text, for outdoors, and every tile takes them. Highlight fills the padlock and the Lock tile while the controls are locked, and outlines a tile just added; it starts yellow. REC keeps its red and each camera its color. Turned off, the page goes back to the standard look, and these colors are kept for next time.")
            }
            Section {
                LabeledContent("Corner Radius") {
                    Text(cornerLabel)
                        .monospacedDigit()
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                // Named on the row above; a Mac form would name it again beside the slider.
                Slider(value: corner, in: AppearanceSettings.corners, step: 1) {
                    Text("Corner Radius")
                } minimumValueLabel: {
                    Image(systemName: "square")
                } maximumValueLabel: {
                    Image(systemName: "app")
                }
                .labelsHidden()
                Button("Reset Corners") { theme.appearance.corner = nil }
                    .disabled(theme.appearance.corner == nil)
            } header: {
                Text("Tile Corners")
            } footer: {
                FooterText("Square corners set each tile apart at a glance, like a key.")
            }
            Section {
                Toggle("Outlines", isOn: $theme.appearance.outlines)
                    .accessibilityIdentifier("outlines")
                if theme.appearance.outlines {
                    LabeledContent("Thickness") {
                        Text(verbatim: Self.points(theme.appearance.outlineWidth))
                            .monospacedDigit()
                            .foregroundStyle(Theme.sheet.secondaryText)
                    }
                    // Named on the row above, as the corner slider is.
                    Slider(value: $theme.appearance.outlineWidth, in: AppearanceSettings.outlineWidths, step: 0.5) {
                        Text("Thickness")
                    } minimumValueLabel: {
                        Image(systemName: "square")
                    } maximumValueLabel: {
                        Image(systemName: "square.fill")
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("outlineWidth")
                }
            } header: {
                Text("Tile Outlines")
            } footer: {
                FooterText("A line around each tile in its camera's color.")
            }
            Section {
                LabeledContent("Size") {
                    Text(verbatim: "\(Int((theme.appearance.textScale * 100).rounded())) %")
                        .monospacedDigit()
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                // Every tile's small type, on any screen. Named on the row above, as the corner slider is.
                Slider(value: $theme.appearance.textScale, in: AppearanceSettings.textScales, step: 0.1) {
                    Text("Text Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .labelsHidden()
                .accessibilityIdentifier("textScale")
                Picker("Text Size", selection: $theme.appearance.textSize) {
                    Text("Standardized").tag(AppearanceSettings.TextSize.standardized)
                    Text("Dynamic").tag(AppearanceSettings.TextSize.dynamic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("textSize")
            } header: {
                Text("Text Size")
            } footer: {
                FooterText("Size makes every tile's titles, labels and buttons bigger, on any screen, up to half again; a title that wouldn't fit stays as big as it can. "
                    + (theme.appearance.textSize == .standardized
                        ? "Standardized: they're one size in every tile, whatever the tile's size."
                        : "Dynamic: a bigger tile draws them, and its values and buttons, bigger still, as far as it keeps the same layout."))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }

    private func colour(_ key: WritableKeyPath<AppearanceSettings, AppearanceSettings.RGB>) -> Binding<AppearanceSettings.RGB> {
        Binding(get: { theme.appearance[keyPath: key] }, set: { theme.appearance[keyPath: key] = $0 })
    }

    private var isDaylight: Bool {
        let a = theme.appearance, d = AppearanceSettings.daylight
        return a.tile == d.tile && a.background == d.background && a.text == d.text
            && a.highlight == AppearanceSettings.standardHighlight
    }

    /// The three at once, so the page redraws once.
    private func resetColours() {
        var a = theme.appearance
        a.tile = AppearanceSettings.daylight.tile
        a.background = AppearanceSettings.daylight.background
        a.text = AppearanceSettings.daylight.text
        a.highlight = AppearanceSettings.standardHighlight
        theme.appearance = a
    }

    private var corner: Binding<Double> {
        Binding(get: { theme.appearance.corner ?? Double(theme.base.corner) },
                set: { theme.appearance.corner = $0 })
    }

    /// "1.5 pt", "2 pt".
    nonisolated static func points(_ value: Double) -> String {
        (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + " pt"
    }

    private var cornerLabel: String {
        let points = Int((theme.appearance.corner ?? Double(theme.base.corner)).rounded())
        return points == 0 ? "Square" : "\(points) pt"
    }
}

/// What Settings says Appearance is set to.
func appearanceSummary(_ appearance: AppearanceSettings) -> String {
    var parts: [String] = []
    if appearance.customColors { parts.append("Custom colors") }
    if let corner = appearance.corner { parts.append(corner == 0 ? "Square corners" : "\(Int(corner.rounded())) pt corners") }
    if appearance.outlines { parts.append("Outlines") }
    if appearance.textScale != 1 { parts.append("Text \(Int((appearance.textScale * 100).rounded())) %") }
    if appearance.textSize == .dynamic { parts.append("Dynamic text") }
    return parts.isEmpty ? "Standard" : parts.joined(separator: " · ")
}

/// Four of camera A's tiles the way the page draws them, in the colors and corners being picked: a captioned value, a
/// switch that's on, the Lock tile locked, and REC.
struct AppearancePreview: View {
    private let tint = SlotColor.red.color

    var body: some View {
        HStack(spacing: Theme.gap) {
            Tile(tint: tint) {
                VStack(alignment: .leading, spacing: Theme.captionGap) {
                    Caption("ISO")
                    Text(verbatim: "800")
                        .font(Theme.value(26))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, Theme.inset)
                .padding(.vertical, Theme.insetV)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Tile(tint: tint, fill: Theme.engaged) {
                Text("False Color")
                    .font(Theme.buttonLabel())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, Theme.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Tile(tint: tint, fill: Theme.locked) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(Theme.symbol(14))
                    Text("Lock").font(Theme.buttonLabel()).lineLimit(1).minimumScaleFactor(0.5)
                }
                .foregroundStyle(Theme.lockedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Tile(tint: tint) {
                GeometryReader { geo in
                    let size = min(geo.size.width, geo.size.height) * 0.62
                    Circle()
                        .fill(Theme.style.recFill)
                        .overlay(Circle().strokeBorder(Theme.recording.opacity(0.9), lineWidth: max(2, size * 0.06)))
                        .frame(width: size, height: size)
                        .overlay(Text("REC").font(Theme.hero(size * 0.24)).foregroundStyle(Theme.recording))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .frame(height: 72)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the page's tiles")
    }
}
