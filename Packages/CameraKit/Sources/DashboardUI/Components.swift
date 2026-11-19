import SwiftUI

private struct ControlsLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The tile's camera is connected and taking commands (`WidgetView` sets it): a value it won't take from here is
    /// set on the camera, not stale.
    @Entry var cameraIsControllable: Bool = false
}

extension EnvironmentValues {
    /// The caption of the tile a control is in (`TileFrame` sets it): what VoiceOver calls the tile's picker.
    @Entry var tileCaption: String? = nil
}

extension EnvironmentValues {
    /// Set by the lock button in the top bar, or the Lock tile: tiles ignore touches so a bump can't change a setting.
    public var controlsLocked: Bool {
        get { self[ControlsLockedKey.self] }
        set { self[ControlsLockedKey.self] = newValue }
    }
}

/// How the Lock tile works the top bar's padlock: one lock for every tile, whichever of the two was tapped. Outside a
/// dashboard (the gallery, previews) it does nothing.
struct ToggleControlsLock: Sendable {
    var toggle: @MainActor @Sendable () -> Void = {}
    @MainActor func callAsFunction() { toggle() }
}

private struct ToggleControlsLockKey: EnvironmentKey {
    static let defaultValue = ToggleControlsLock()
}

extension EnvironmentValues {
    var toggleControlsLock: ToggleControlsLock {
        get { self[ToggleControlsLockKey.self] }
        set { self[ToggleControlsLockKey.self] = newValue }
    }
}

private struct LUTNamesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    /// The names set in Settings for the cameras' LUTs (`DashboardStore.lutNames`).
    var lutNames: [String: String] {
        get { self[LUTNamesKey.self] }
        set { self[LUTNamesKey.self] = newValue }
    }
}

/// What the LUT picker calls a LUT: the name set in Settings, else the camera's. S-Log3 is the camera's own log
/// picture with no LUT on it, so it says so.
func lutTitle(_ name: String, names: [String: String]) -> String {
    if let custom = names[name], !custom.trimmingCharacters(in: .whitespaces).isEmpty { return custom }
    if name == "S-Log3" { return "S-Log3 (No LUT)" }
    // A Blackmagic camera names its LUTs by file: "Blackmagic Gen 5 Film Look.cube" shows as "Blackmagic Gen 5 Film Look".
    return name.lowercased().hasSuffix(".cube") ? String(name.dropLast(5)) : name
}

private struct AlignmentAuditKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The alignment audit (`AlignmentAudit`), on for a render: the name the findings give the tile (what's above
    /// a tile sets a prefix, "" to turn it on). nil in the app.
    public var alignmentAudit: String? {
        get { self[AlignmentAuditKey.self] }
        set { self[AlignmentAuditKey.self] = newValue }
    }
}

/// How a caption is laid out, for the alignment audit: in a `CaptionRow` (with whatever sits beside it), leading a
/// line it's centered on (a one-line tile, a short slider), or anywhere else.
enum CaptionPlacement: Sendable {
    case free, row, line
}

private struct CaptionPlacementKey: EnvironmentKey {
    static let defaultValue = CaptionPlacement.free
}

extension EnvironmentValues {
    var captionPlacement: CaptionPlacement {
        get { self[CaptionPlacementKey.self] }
        set { self[CaptionPlacementKey.self] = newValue }
    }
}

/// Where a tile's captions are, in the tile (those in a `CaptionRow` again in `rowCaptions`), its values and the areas
/// they're laid out in, and the tile's size.
struct CaptionFrames: PreferenceKey {
    static let defaultValue = Value()
    struct Value: Equatable, Sendable {
        var captions: [CGRect] = []
        var rowCaptions: [CGRect] = []
        var lineCaptions: [CGRect] = []
        /// Each caption's baseline, where its leading edge meets it.
        var baselines: [CGPoint] = []
        /// A value's text, and the space under a caption row (`contentAreas`) or the one line (`lineAreas`) it sits in.
        var values: [CGRect] = []
        var contentAreas: [CGRect] = []
        var lineAreas: [CGRect] = []
        /// A control (a slider, a switch, a step button): the overflow check wants it inside the tile.
        var controls: [CGRect] = []
        var tile: CGSize?
        /// The tile's Dynamic Text Size scale (`tileScale`): its caption band and caption row are that much lower.
        var scale: CGFloat?
    }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.captions += next.captions
        value.baselines += next.baselines
        value.rowCaptions += next.rowCaptions
        value.lineCaptions += next.lineCaptions
        value.values += next.values
        value.contentAreas += next.contentAreas
        value.lineAreas += next.lineAreas
        value.controls += next.controls
        value.tile = value.tile ?? next.tile
        value.scale = value.scale ?? next.scale
    }
}

/// What an audited frame is: a value's text, the space a two-row tile gives its content, or a one-line tile's line.
enum AuditedFrame {
    case value, content, line, control
}

private struct AuditFrameModifier: ViewModifier {
    let kind: AuditedFrame
    @Environment(\.alignmentAudit) private var audit

    func body(content: Content) -> some View {
        content.background {
            if audit != nil {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named(CaptionFrames.space))
                    Color.clear.preference(key: CaptionFrames.self, value: CaptionFrames.Value(
                        values: kind == .value ? [frame] : [], contentAreas: kind == .content ? [frame] : [],
                        lineAreas: kind == .line ? [frame] : [], controls: kind == .control ? [frame] : []))
                }
            }
        }
    }
}

extension View {
    /// Reports this frame to the alignment audit (nothing in the app).
    func audited(_ kind: AuditedFrame) -> some View {
        modifier(AuditFrameModifier(kind: kind))
    }
}

/// Checks a render for the alignment the style guide sets (§ Alignment), so a tile that breaks it fails the snapshot
/// instead of waiting for someone to spot a 2 pt step on an iPad:
/// - captions on one line sit at one height (the Naming tile had "NAMING" centered and "ID" on its value's baseline);
/// - a caption at the top of a two-row tile is in a `CaptionRow` (hand-made rows put ND −/+ 1.5 pt higher);
/// - every tile's caption row sits at one height (a switch beside ISO's caption lifted it 1 pt; the WB sliders' once
///   sat 3 pt lower);
/// - a value starts at its area's left edge and sits in the middle of it, under a caption row or on the one line
///   (HaLow's sat at the bottom, and WB's in a short tile).
/// The snapshot tool turns it on (`CC_SNAPSHOT_AUDIT`, and always for the gallery) and prints what it finds.
@MainActor
public enum AlignmentAudit {
    /// Per tile, what's wrong with it (nil: nothing), and its caption row's height where it has one.
    static var findings: [String: String] = [:]
    static var captionRows: [String: (y: CGFloat, scale: CGFloat)] = [:]

    static func record(_ tile: String, _ frames: CaptionFrames.Value) {
        guard let size = frames.tile else { return }
        let scale = frames.scale ?? 1
        var problems: [String] = []
        // Nothing is cut off: every caption, value and control lies inside its tile (the design system's one rule for
        // size, docs/design-style-guide.md § 1).
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
        // A caption by its letters: capitals, no descenders, so its line box less 2 pt above and below at 10 pt (the box
        // is 13 pt and the capitals 7). A phone on its side draws 12 pt tiles whose captions read whole.
        // In proportion to the caption's own line, whatever its size (Dynamic's scale, or the slider's bigger type).
        let letters = frames.captions.map { $0.insetBy(dx: 0, dy: $0.height * 2 / 13) }
        for (what, rects) in [("caption", letters), ("value", frames.values), ("control", frames.controls)] {
            for rect in rects where !rect.isEmpty && !bounds.contains(rect) {
                problems.append(String(format: "a %@ cut off at (%.1f, %.1f, %.1f × %.1f) in a %.0f × %.0f tile",
                                       what, rect.minX, rect.minY, rect.width, rect.height, size.width, size.height))
            }
        }
        guard !frames.captions.isEmpty else {
            findings[tile] = problems.isEmpty ? nil : problems.joined(separator: "; ")
            return
        }
        // Captions line up by their baselines: the same as by their middles when they're one size, and right for one
        // that gave way to a narrow line at a bigger Text Size (smaller, on its neighbors' baseline).
        func baseline(_ caption: CGRect) -> CGFloat {
            frames.baselines.first { abs($0.x - caption.minX) < 0.5 && $0.y >= caption.minY - 0.5 && $0.y <= caption.maxY + 0.5 }?.y
                ?? caption.midY
        }
        // Captions whose lines overlap are on one line.
        let captions = frames.captions.sorted { $0.minY < $1.minY }
        for (i, a) in captions.enumerated() {
            for b in captions[(i + 1)...] where b.minY < a.maxY - 1 && abs(baseline(a) - baseline(b)) > 0.5 {
                problems.append(String(format: "captions on one line with baselines at y %.1f and %.1f", baseline(a), baseline(b)))
            }
        }
        // A caption in the top band that isn't centered on the tile, or leading a line, belongs to a caption row.
        let band = (Theme.insetV + Theme.captionRow + 2) * scale
        let placed = frames.rowCaptions + frames.lineCaptions
        for caption in captions where caption.midY < band && abs(caption.midY - size.height / 2) > 1
            && !placed.contains(where: { abs($0.midY - caption.midY) < 0.01 && abs($0.minX - caption.minX) < 0.01 }) {
            problems.append(String(format: "a caption at the top (y %.1f) outside a CaptionRow", caption.midY))
        }
        captionRows[tile] = frames.rowCaptions.min(by: { $0.minY < $1.minY }).map { (y: (baseline($0) * 2).rounded() / 2, scale: scale) }
        for value in frames.values {
            let centre = CGPoint(x: value.midX, y: value.midY)
            if let area = frames.contentAreas.first(where: { $0.contains(centre) }) {
                if abs(value.midY - area.midY) > 1 {
                    problems.append(String(format: "a value at y %.1f, the middle of its area at %.1f", value.midY, area.midY))
                }
                if abs(value.minX - area.minX) > 0.5 {
                    problems.append(String(format: "a value at x %.1f, its area starts at %.1f", value.minX, area.minX))
                }
            } else if let line = frames.lineAreas.first(where: { $0.contains(centre) }), abs(value.midY - line.midY) > 1 {
                problems.append(String(format: "a value at y %.1f on a line centred at %.1f", value.midY, line.midY))
            }
        }
        findings[tile] = problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Everything wrong in the render: the tiles' own findings, and caption rows off the height most tiles of their
    /// scale have (Dynamic Text Size draws a bigger tile's caption row lower; tiles of one scale still line up).
    public static func report() -> [String] {
        var lines = findings.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        let byScale = Dictionary(grouping: captionRows, by: { $0.value.scale })
        for scale in byScale.keys.sorted() {
            let rows = byScale[scale] ?? []
            let counts = Dictionary(grouping: rows.map(\.value.y), by: { $0 }).mapValues(\.count)
            guard let usual = counts.max(by: { $0.value < $1.value })?.key else { continue }
            for row in rows.sorted(by: { $0.key < $1.key }) where abs(row.value.y - usual) > 0.5 {
                lines.append(String(format: "%@: caption row at y %.1f, every other tile's at %.1f", row.key, row.value.y, usual))
            }
        }
        return lines
    }

    public static func reset() {
        findings = [:]
        captionRows = [:]
    }
}

/// The rounded, color-bordered panel every control sits in.
struct Tile<Content: View>: View {
    var tint: Color
    var badge: String? = nil
    var badgeColor: Color? = nil
    var fill: Color = Theme.tile
    var isEnabled: Bool = true
    /// Takes taps while the controls are locked: the Lock tile, or nothing on the page could unlock them.
    var ignoresLock: Bool = false
    /// Something to read rather than a control (the camera's letter, battery and media, timecode, latency, HaLow, live
    /// view's picture, REC while it rolls): it keeps its brightness while the controls are locked, where controls dim.
    var isReadout: Bool = false
    @ViewBuilder var content: () -> Content

    @Environment(\.controlsLocked) private var locked
    @Environment(\.alignmentAudit) private var audit
    @Environment(\.tileScale) private var tileScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(fill)
                .background {
                    if audit != nil {
                        GeometryReader { geo in
                            Color.clear.preference(key: CaptionFrames.self,
                                                   value: CaptionFrames.Value(tile: geo.size, scale: tileScale))
                        }
                    }
                }
            // minWidth/minHeight 0 + clip: a tile always takes exactly the space the row gives it.
            // Content that can't fit gets clipped instead of growing the tile over its neighbors.
            content()
                .environment(\.tileTint, tint)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                // Locked, a control grays so the page reads as locked; a control the camera hasn't got stays at its
                // own, dimmer level rather than fading further.
                .opacity(!isEnabled ? 0.28 : locked && !ignoresLock && !isReadout ? Theme.lockedOpacity : 1)
                .allowsHitTesting(isEnabled && (!locked || ignoresLock))
            // Over the content: a picture filling the tile (Live View) still shows the border. Ink has none unless
            // Settings → Appearance turns outlines on: its captions carry the camera's color (`Caption`).
            if Theme.style.drawsOutline {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(tint, lineWidth: Theme.border)
                    .allowsHitTesting(false)
            }
            if let badge {
                Text(badge)
                    .font(Theme.caption)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(badgeColor ?? tint, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(7)
            }
        }
        .coordinateSpace(name: CaptionFrames.space)
        // One group per tile, so VoiceOver reads a tile through before the next. Without it, a row of tiles was read
        // captions first ("FPS, CODEC"), then the values.
        .accessibilityElement(children: .contain)
        .onPreferenceChange(CaptionFrames.self) { frames in
            guard let audit else { return }
            MainActor.assumeIsolated { AlignmentAudit.record(audit, frames) }
        }
    }
}

extension CaptionFrames {
    static let space = "tile"
}

private struct TileTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The camera color of the tile this view is in: Ink puts it in the captions.
    var tileTint: Color? {
        get { self[TileTintKey.self] }
        set { self[TileTintKey.self] = newValue }
    }
}

/// Pill-style segmented control ("Fixed | Variable", "AF-C | MF"). `small` is the header size, for a mode switch
/// beside a tile's caption ("800 | 12800" base ISO, "ANG | SPD").
struct MiniSegmented<Value: Hashable>: View {
    var options: [Value]
    var selection: Value?
    var label: (Value) -> String
    var isEnabled: Bool = true
    var small = false
    /// Segment height when the tile can't give the standard 30pt (a squeezed iPhone row): never outgrow the tile.
    /// In standard points, like every size given to a tile's controls: the control scales it (`tileScale`).
    var segmentHeight: CGFloat? = nil
    /// What VoiceOver says for a segment, where `label` is a short form of it ("Angle" for "Ang"). Default: `label`.
    var spoken: ((Value) -> String)? = nil
    var onSelect: (Value) -> Void
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        HStack(spacing: 2 * s) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    onSelect(option)
                } label: {
                    ZStack {
                        // Full size, the segments share the width equally, so each wants the widest label's room: as
                        // wide as each label's own (a `ViewThatFits` would let the narrower half shrink to half-width).
                        if !small {
                            ForEach(options.filter { $0 != option }, id: \.self) { text($0).hidden() }
                        }
                        text(option)
                            .foregroundStyle(selected ? Theme.style.controlSelectedText : Theme.secondaryText)
                    }
                    .padding(.horizontal, (small ? 6 : 4) * s)
                    .frame(maxWidth: small ? nil : .infinity,
                           minHeight: (segmentHeight ?? (small ? 16 * (shortLine ? 1 : Theme.textBump) : 30)) * s)
                    .background(selected ? Theme.controlSelected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4 * s, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Which segment the camera has: VoiceOver read them all alike, set or not.
                .accessibilityLabel(spoken?(option) ?? label(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2 * s)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
        .fixedSize(horizontal: small, vertical: false)
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
        .audited(.control)
    }

    private func text(_ option: Value) -> some View {
        Text(verbatim: small ? label(option).uppercased() : label(option))
            .font(small ? Theme.caption(Theme.textScale(s, shortLine: shortLine)) : Theme.segment(Theme.textScale(s, shortLine: shortLine)))
            .tracking(small ? 0.4 * s : 0)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// A tile's two-way mode switch: Shutter's Angle | Speed, FPS's Fixed | Variable. One control for both, sized by where
/// the tile puts it, so tiles of one size show the same switch. In the header or on one line: the small segmented
/// control (caption type, 20 pt), or, where
/// even that won't fit, one chip showing the mode that flips it. In a column or along the bottom: full size (30 pt).
struct ModeSwitch<Value: Hashable>: View {
    var options: [Value]
    var selection: Value?
    /// "Angle", "Variable": in a column or along the bottom.
    var full: (Value) -> String
    /// "Ang", "Var": in the header and on the chip.
    var short: (Value) -> String
    var placement: SwitchPlacement
    var isEnabled: Bool = true
    var onSelect: (Value) -> Void

    var body: some View {
        // VoiceOver gets the whole word wherever the switch shows the short one ("ANG" was read out as letters).
        if placement.isSmall {
            ViewThatFits(in: .horizontal) {
                MiniSegmented(options: options, selection: selection, label: short, isEnabled: isEnabled, small: true,
                              spoken: full, onSelect: onSelect)
                PillToggle(title: selection.map(short) ?? "—", lit: nil, isEnabled: isEnabled,
                           spokenTitle: selection.map(full)) {
                    if let next = next { onSelect(next) }
                }
            }
        } else {
            // "Fixed | Var" where "Fixed | Variable" would squeeze (a footer beside its caption).
            ViewThatFits(in: .horizontal) {
                MiniSegmented(options: options, selection: selection, label: full, isEnabled: isEnabled, small: false,
                              onSelect: onSelect)
                MiniSegmented(options: options, selection: selection, label: short, isEnabled: isEnabled, small: false,
                              spoken: full, onSelect: onSelect)
            }
        }
    }

    /// The option after the one selected, round to the first.
    private var next: Value? {
        guard let selection, let index = options.firstIndex(of: selection) else { return options.first }
        return options[(index + 1) % options.count]
    }
}

/// Horizontal slider with a custom track (gradient for Kelvin/tint, ticks for iris).
/// - Drag the knob to change; the value commits once on release, so a drag doesn't flood the camera link.
/// - A single tap does nothing, so a stray touch on set can't move a setting.
/// - Double-tap resets to `resetFraction` when there is one (tint to 0, temperature to 5600K).
/// - With `stepFraction`, ‹ › at the ends move it one camera step per tap.
struct TrackSlider: View {
    var fraction: Double
    var track: AnyShapeStyle
    /// Small marks on the track, as 0...1 positions (e.g. tint's zero).
    var marks: [Double] = []
    var resetFraction: Double? = nil
    /// One camera step as a fraction of the track, for the ‹ › buttons. nil: no buttons.
    var stepFraction: Double? = nil
    var isEnabled: Bool = true
    var onCommit: (Double) -> Void

    @State private var dragFraction: Double?
    /// What was last sent, shown until the camera reports a new value (or for 3 s, if it never does). Without it the
    /// knob jumped back to the old value for the round trip, then on to the new one.
    @State private var sentFraction: Double?
    @Environment(\.tileScale) private var s

    private static let nudgeWidth: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            // Buttons only where the track keeps a usable length.
            let nudges = stepFraction != nil && geo.size.width >= 150 * s
            HStack(spacing: 0) {
                if nudges { nudgeButton(-1, height: geo.size.height) }
                trackView(width: geo.size.width - (nudges ? 2 * Self.nudgeWidth * s : 0), height: geo.size.height)
                if nudges { nudgeButton(1, height: geo.size.height) }
            }
            .audited(.control)
        }
        .onChange(of: fraction) { sentFraction = nil }
        .task(id: sentFraction) {
            guard sentFraction != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { sentFraction = nil }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }

    private func trackView(width: CGFloat, height: CGFloat) -> some View {
        let knob = min(height, 24 * s)
        let usable = max(width - knob, 1)
        let shown = min(max(dragFraction ?? sentFraction ?? fraction, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(track)
                .frame(height: 4 * s)
                .padding(.horizontal, knob / 2)
            ForEach(marks, id: \.self) { mark in
                Capsule()
                    .fill(Theme.strong.opacity(0.85))
                    .frame(width: 2 * s, height: 10 * s)
                    .offset(x: knob / 2 - s + usable * CGFloat(min(max(mark, 0), 1)))
            }
            Circle()
                .fill(Theme.strong)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.45), radius: 2 * s, y: s)
                .offset(x: usable * CGFloat(shown))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    dragFraction = min(max((drag.location.x - knob / 2) / usable, 0), 1)
                }
                .onEnded { _ in
                    if let committed = dragFraction { send(committed) }
                    dragFraction = nil
                }
        )
        .onTapGesture(count: 2) {
            if let resetFraction { send(resetFraction) }
        }
    }

    /// As tall as the track's slot, never taller: a nudge button taller than its slot hangs below the tile.
    private func nudgeButton(_ direction: Double, height: CGFloat) -> some View {
        Button {
            // From what was last sent, so quick taps add up before the camera answers.
            if let stepFraction { send(min(max((sentFraction ?? fraction) + direction * stepFraction, 0), 1)) }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(Theme.symbol(12 * s, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: Self.nudgeWidth * s, height: min(26 * s, max(height, 12 * s)))
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction < 0 ? "One step down" : "One step up")
    }

    private func send(_ value: Double) {
        sentFraction = value
        onCommit(value)
    }
}

/// The camera's options behind any label. With nothing to pick (read-only on this body, no camera link, or no
/// options) there's no menu: the label is told, so it drops its chevron and grays out.
/// One action after a picker's options, below a divider ("Load LUT onto Camera…").
struct MenuExtra {
    var title: String
    var systemImage: String
    var action: () -> Void
}

struct ChoiceMenu<Value: Hashable, Label: View>: View {
    var options: [Value]
    var title: (Value) -> String
    var isEnabled: Bool
    /// The value the camera has: ticked in the menu, as a picker's menu ticks it. The menus listed the options with
    /// nothing to say which was set (the 11/16 UI audit).
    var current: Value? = nil
    var onSelect: (Value) -> Void
    var extra: MenuExtra? = nil
    /// What VoiceOver gives as the menu's value. Default: the current option's title.
    var spokenValue: String? = nil
    @ViewBuilder var label: (_ live: Bool) -> Label
    @Environment(\.tileCaption) private var caption

    var body: some View {
        let live = isEnabled && !options.isEmpty
        // The label is laid out like any view and the menu sits over it as a clear tap target. As the menu's own
        // label, macOS measured it with the wrong font and shrank the text ("Class 300" at half size).
        label(live)
            .overlay {
                if live {
                    Menu {
                        Picker(selection: Binding(get: { current }, set: { if let value = $0 { onSelect(value) } })) {
                            ForEach(options, id: \.self) { option in
                                Text(title(option)).tag(Optional(option))
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        if let extra {
                            Divider()
                            Button(action: extra.action) { SwiftUI.Label(extra.title, systemImage: extra.systemImage) }
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    // Named by its tile's caption, and set to the camera's value: it read as an unnamed button.
                    .accessibilityLabel(caption ?? "")
                    .accessibilityValue(spokenValue ?? current.map(title) ?? "")
                }
            }
    }
}

/// Circular −/+ button used inside the ND preset tile.
struct RoundIconButton: View {
    var systemName: String
    var isEnabled: Bool = true
    /// In standard points: the button scales it (`tileScale`).
    var diameter: CGFloat = 20
    var action: () -> Void
    @Environment(\.tileScale) private var s

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.symbol((diameter > 24 ? 14 : 11) * s, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: diameter * s, height: diameter * s)
                .background(Theme.control, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .audited(.control)
    }
}

/// A tile's caption: "ISO", "CODEC", "TEMP". One style in every tile, so tiles read as one family.
/// Captions never shrink, so every caption is the same size; one that can't fit whole is dropped by its tile, never cut
/// to a few letters ("CO…" read as broken).
struct Caption: View {
    var text: String
    var color: Color = Theme.secondaryText
    /// No color of its own was asked for: Ink puts the tile's camera color here.
    private var isPlain = true
    @Environment(\.alignmentAudit) private var audit
    @Environment(\.tileTint) private var tileTint
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color ?? Theme.secondaryText
        self.isPlain = color == nil
    }

    var body: some View {
        let t = Theme.textScale(s, shortLine: shortLine)
        Text(verbatim: text.uppercased())
            .font(Theme.caption(t))
            .tracking(Theme.captionTracking(t))
            .foregroundStyle(isPlain && Theme.style.identity == .ink ? (tileTint.map(Theme.legible) ?? color) : color)
            .lineLimit(1)
            // Bigger than the standard (Text Size), a caption gives way to a line too narrow for it, down to the
            // standard size: bigger where it fits, never smaller than at 100 %.
            .minimumScaleFactor(min(1, 1 / (t * Theme.textBump)))
            .background {
                if audit != nil {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .named(CaptionFrames.space))
                        Color.clear.preference(key: CaptionFrames.self, value: CaptionFrames.Value(
                            captions: [frame], rowCaptions: placement == .row ? [frame] : [],
                            lineCaptions: placement == .line ? [frame] : []))
                    }
                }
            }
            // Its baseline, for the audit: a caption that gave way is smaller than its neighbors, on their baseline.
            .background(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                if audit != nil {
                    Color.clear.frame(width: 0, height: 0).background {
                        GeometryReader { geo in
                            let point = geo.frame(in: .named(CaptionFrames.space)).origin
                            Color.clear.preference(key: CaptionFrames.self, value: CaptionFrames.Value(baselines: [point]))
                        }
                    }
                }
            }
    }

    @Environment(\.captionPlacement) private var placement
}

/// A tile's caption row: `captionHeight` high, with its caption on the same baseline in every tile. Whatever goes
/// beside the caption (a readout on its baseline, switches) is laid over the row by baseline, so it can overhang the
/// row but never move the caption: in an HStack centered in the row, ISO's Base switch lifted its caption 1 pt above
/// its neighbors'. Every caption at the top of a tile goes through this (the alignment audit checks).
struct CaptionRow<Accessory: View>: View {
    var caption: String
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    init(_ caption: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.caption = caption
        self.accessory = accessory
    }

    var body: some View {
        CaptionStrut()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Theme.captionRow(Theme.textScale(s, shortLine: shortLine)))
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                    // The tile's caption is a heading: VoiceOver's rotor goes tile to tile by them.
                    Caption(caption).fixedSize(horizontal: s * Theme.textBump == 1, vertical: s * Theme.textBump == 1).layoutPriority(2)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4 * s)
                    accessory().layoutPriority(1)
                }
                .environment(\.captionPlacement, .row)
            }
    }
}

extension CaptionRow where Accessory == EmptyView {
    init(_ caption: String) {
        self.init(caption) { EmptyView() }
    }
}

/// A caption and its value inside a tile's content ("ID A", "REEL 1"). Caption and value align on their cap centers,
/// not their line-box midpoints: different font sizes share the same visual baseline, so "ID" and "A" sit level.
/// Every caption + value pair inside a tile goes through this; a hand-made HStack on first baselines put "ID" lower
/// than the tile's "NAMING" caption beside it.
struct CaptionedValue: View {
    var caption: String
    var value: String
    var size: CGFloat
    var color: Color = Theme.text
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    init(_ caption: String, _ value: String, size: CGFloat, color: Color = Theme.text) {
        self.caption = caption
        self.value = value
        self.size = size
        self.color = color
    }

    var body: some View {
        HStack(alignment: .capCenter, spacing: 6 * s) {
            Caption(caption)
                .capCentered(10 * Theme.textScale(s, shortLine: shortLine) * Theme.textBump, weight: .heavy)
            Text(verbatim: value)
                .font(Theme.value(size))
                .foregroundStyle(color)
                .capCentered(size, weight: .bold)
        }
    }
}

/// Zero-width text in the readout font. Put first in a caption row (aligned on first baselines), it gives every
/// caption row the metrics of one holding a readout (f-number, Kelvin), so captions sit at the same height in
/// every tile (the WB sliders' caption sat 3pt lower than the WB preset's beside it).
struct CaptionStrut: View {
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        Text(verbatim: "0").font(Theme.readout(Theme.textScale(s, shortLine: shortLine))).hidden().frame(width: 0)
    }
}

/// The picker affordance, ⌄: a menu drops down from the tile, in place. Same symbol, size and color in every tile,
/// always at the trailing edge. A tile that opens a window instead gets `SheetChevron`.
struct Chevron: View {
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        Image(systemName: "chevron.down")
            .font(Theme.chevron(Theme.textScale(s, shortLine: shortLine)))
            .foregroundStyle(Theme.secondaryText)
            // For the eye only: the menu over the tile is the button. VoiceOver read the symbol out as "Go Down".
            .accessibilityHidden(true)
    }
}

/// Parts at their own widths, each starting an equal column, so a row fills a wide tile without stretching or
/// truncating anything (the Naming tile's ID and reel). Its ideal width is the parts' own, so `ViewThatFits` measures it
/// as it is and falls back while it doesn't fit; a part wider than its column pushes the next along.
struct ColumnsRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        let height = sizes.map(\.height).max() ?? 0
        guard let width = proposal.width, width.isFinite else { return CGSize(width: natural, height: height) }
        return CGSize(width: max(width, natural), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let column = bounds.width / CGFloat(subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            x = max(x, bounds.minX + column * CGFloat(index))
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

/// ›: the tile opens a window (Naming, Monitoring Options), where ⌄ would promise a menu. Same size and color as
/// `Chevron`, in the same place.
struct SheetChevron: View {
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        Image(systemName: "chevron.forward")
            .font(Theme.chevron(Theme.textScale(s, shortLine: shortLine)))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityHidden(true)   // as `Chevron`'s: VoiceOver said "Forward"
    }
}

/// A small switch for a tile's header, the same height as `MiniSegmented(small:)`. `lit` true shows it on
/// (green), false off; nil is a neutral chip that shows a mode ("ANG").
struct PillToggle: View {
    var title: String
    var lit: Bool?
    var isEnabled: Bool = true
    /// 20 in a header; taller where the switch has its own column (easier to hit). In standard points: the switch
    /// scales it (`tileScale`). A taller one gives way to a line shorter than it, down to a small control's 20 pt: on a
    /// phone on its side a one-line LUT tile is 27 pt, and its 28 pt switches were cut off.
    var height: CGFloat = 20
    /// What VoiceOver says, where `title` is a short form ("Angle" for the chip's "ANG"). Default: the title as shown.
    var spokenTitle: String? = nil
    var action: () -> Void
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine
    private var pillHeight: CGFloat { (height > 24 || shortLine ? height : height * Theme.textBump) * s }

    var body: some View {
        Button(action: action) {
            Text(verbatim: title.uppercased())
                .font(Theme.caption(Theme.textScale(s, shortLine: shortLine)))
                .tracking(0.4 * s)
                .foregroundStyle(lit == true ? Theme.timecode : lit == false ? Theme.secondaryText : Theme.text)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, (height > 24 ? 10 : 7) * s)
                // A small one holds the slider's bigger caption type (Text Size): it grows with it.
                .frame(minHeight: min(height, Theme.smallControl) * s, idealHeight: pillHeight, maxHeight: pillHeight)
                .background(lit == true ? Theme.timecode.opacity(0.18) : Theme.control,
                            in: RoundedRectangle(cornerRadius: 6 * s, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenTitle ?? title.uppercased())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .audited(.control)
    }
}

/// Where a tile's mode switches go. In the header they're small; with room, they get their own column on the
/// right or a row along the bottom of a tall, narrow tile, at a size that's easy to hit. Inline: the one-line layout.
enum SwitchPlacement {
    case header, trailing, footer, inline

    /// Header and inline switches are the small size.
    var isSmall: Bool { self == .header || self == .inline }
}

/// The anatomy every captioned tile shares: a caption row above the main content at the same insets everywhere, and
/// the tile's mode switches placed by `SwitchPlacement`. A tile too short for two rows puts caption, content and
/// switches on one line. `main` receives whether it's on one line and roughly the size it has.
/// - `oneLineBelow`: the height below which it goes to one line (a segmented control needs more than a value).
/// - `trailingFrom`: from this width the switches get a column on the right; `footerFrom`: from this height (and
///   too narrow for a column) a row along the bottom. Neither: they stay in the header.
struct TileFrame<Main: View, Accessory: View>: View {
    var caption: String
    /// The switches' own caption ("BASE", "MONITOR"). In a column it sits on the tile's caption row, left-aligned
    /// over the switch, so a tile reads as two small ones; along the bottom it leads the row.
    /// nil when this camera gives the tile no switches: they then never get a column or row.
    var switchCaption: String? = nil
    var oneLineBelow: CGFloat = Theme.oneLineBelow
    var trailingFrom: CGFloat? = nil
    var footerFrom: CGFloat? = nil
    /// On one line, the value wins over the caption (`OneLineRow`): for a tile whose content is its value (a picker's
    /// `PickerValue`). Content that has its own ways to fit (Naming's reel, Playback's buttons) keeps the caption whole.
    var valueWins = false
    @ViewBuilder var main: (_ oneLine: Bool, _ size: CGSize) -> Main
    @ViewBuilder var accessory: (_ placement: SwitchPlacement) -> Accessory
    /// Dynamic Text Size: insets, caption row and gaps are this many times the standard, and so are the heights and
    /// widths it compares its size with, so it lays out as the standard tile at its size over `s` does.
    @Environment(\.tileScale) private var s

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let inset = Theme.inset * s
            let inner = size.width - 2 * inset
            if size.height < (oneLineBelow + Theme.captionRowGrowth) * s {
                Group {
                    if valueWins {
                        // A VENICE's Shutter on a phone on its side read "1…" beside a whole "SHUTTER" and ANG | SPD.
                        OneLineRow(spacing: 8 * s) {
                            Caption(caption).environment(\.captionPlacement, .line).accessibilityAddTraits(.isHeader)
                            HStack(spacing: 8 * s) { main(true, CGSize(width: inner, height: size.height)) }
                            // A tile shorter than a small control drops its switches rather than cut them off (§ 1).
                            if size.height >= Theme.smallControl * s {
                                HStack(spacing: 8 * s) { accessory(.inline) }
                            }
                        }
                    } else {
                        HStack(spacing: 8 * s) {
                            Caption(caption).fixedSize(horizontal: s * Theme.textBump == 1, vertical: s * Theme.textBump == 1)
                                .layoutPriority(2)
                                .environment(\.captionPlacement, .line)
                                .accessibilityAddTraits(.isHeader)
                            main(true, CGSize(width: inner, height: size.height))
                            if size.height >= Theme.smallControl * s {
                                accessory(.inline).layoutPriority(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .frame(width: size.width, height: size.height)
                .environment(\.shortLine, size.height < Theme.captionLine(s))
                .audited(.line)
            } else {
                let insetV = Theme.insetV * s
                let gap = Theme.captionGap * s
                let body = size.height - 2 * insetV - Theme.captionRow(s) - gap
                // A column or a bottom row only for a tile that has switches (a switch caption says it does): an FX3
                // has no S&Q, and an empty "S&Q" column is a hole.
                let hasSwitches = switchCaption != nil
                // A column only where its full-size switches (34 pt) fit in the tile under its caption: in a wide tile
                // just tall enough for two rows, switches at a bigger Text Size hung out of the bottom.
                let column = (Theme.insetV + Theme.captionRow + Theme.captionGap + 34) * s
                let placement: SwitchPlacement =
                    hasSwitches && trailingFrom.map { size.width >= $0 * s } == true && size.height >= column ? .trailing
                    : hasSwitches && footerFrom.map { size.height >= $0 * s } == true ? .footer : .header
                Group {
                    switch placement {
                    case .trailing:
                        // Two columns with one caption row: the value and the switches, each centered in the same
                        // height below its caption, so they line up.
                        HStack(alignment: .top, spacing: 12 * s) {
                            VStack(alignment: .leading, spacing: gap) {
                                CaptionRow(caption)
                                main(false, CGSize(width: inner * 0.6, height: max(body, 1)))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    .audited(.content)
                            }
                            VStack(alignment: .leading, spacing: gap) {
                                // The column is at least as wide as its caption: a CaptionRow draws its caption over a
                                // strut, so under one narrow switch "Monitor" ran past the tile (a PYXIS's LUT tile).
                                ZStack(alignment: .topLeading) {
                                    // Its width only (a Text, not a Caption, which the alignment audit would count).
                                    Text(verbatim: (switchCaption ?? "").uppercased())
                                        .font(Theme.caption(s)).tracking(Theme.captionTracking(s))
                                        .fixedSize().hidden().frame(height: 0)
                                    CaptionRow(switchCaption ?? "")
                                }
                                accessory(.trailing).fixedSize().frame(maxHeight: .infinity)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    case .footer:
                        VStack(alignment: .leading, spacing: gap) {
                            CaptionRow(caption)
                            main(false, CGSize(width: inner, height: max(body - 36 * s, 1)))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .audited(.content)
                            HStack(spacing: 8 * s) {
                                if let switchCaption { Caption(switchCaption).fixedSize(horizontal: s * Theme.textBump == 1, vertical: s * Theme.textBump == 1) }
                                accessory(.footer)
                            }
                            .padding(.top, 3 * s)
                        }
                    default:
                        VStack(alignment: .leading, spacing: gap) {
                            // The caption never truncates; the switches get the rest of the row and overhang the
                            // caption line rather than push the value down.
                            // The accessory gets an extra top offset so corner switches sit equidistant from the
                            // top and trailing edges of the tile (inset = 10 pt, insetV = 7 pt → +3 pt).
                            CaptionRow(caption) { accessory(.header).padding(.top, inset - insetV) }
                            main(false, CGSize(width: inner, height: max(body, 1)))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .audited(.content)
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, insetV)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .environment(\.tileCaption, caption)
    }
}

/// A tile's one line: caption, content, switches, and the content wins. Each at its own
/// width where all fit, the content taking what's left as an HStack gave it. Short of that, in order: the content gives
/// up to 15 % (its type scales down); the switches give way, to a chip at their narrowest; the caption gives way, whole
/// (the content says what it is, as Latency's reading does without its caption); and only then does the content
/// shrink further. Cut to a few letters, a caption read as broken ("CO…", "BITR…" on a page of four cameras, the 11/16
/// UI audit). Laid out as an HStack: each centered on the line, `spacing` apart, sized for the height it's given (a
/// short line's type scales down to fit it).
struct OneLineRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal.width, height: proposal.height, subviews: subviews)
        let sizes = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)) }
        let used = widths.filter { $0 > 0 }
        return CGSize(width: used.reduce(0, +) + spacing * CGFloat(max(used.count - 1, 0)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, height: proposal.height, subviews: subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: proposal.height))
            if width > 0 { x += width + spacing }
        }
    }

    /// Caption, content and switches' widths in `total` (nil: their own). A missing or empty one is 0, with no spacing.
    func widths(_ total: CGFloat?, height: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let own = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let total, subviews.count >= 2 else { return own.map(\.width) }
        // On a line shorter than its type, the content's type scales down to the height, and so does its width.
        let shrink = height.map { own[1].height > 0 ? min(1, $0 / own[1].height) : 1 } ?? 1
        let c = own[0].width, v = own[1].width * shrink, w = subviews.count > 2 ? own[2].width : 0
        let vMost = subviews[1].sizeThatFits(ProposedViewSize(width: total, height: height)).width
        let wLeast = subviews.count > 2 ? subviews[2].sizeThatFits(ProposedViewSize(width: 0, height: height)).width : 0
        let room = total - spacing * CGFloat([c, v, w].filter { $0 > 0 }.count - 1)
        var split = Self.split(room: room, caption: c, content: v, contentMost: vMost, switches: w, switchesLeast: wLeast)
        // A caption that gave way leaves its spacing to the content.
        if c > 0, split[0] == 0, v > 0 { split[1] += spacing }
        return Array(split.prefix(subviews.count))
    }

    /// Who gets what of `room`, from what each wants: caption, content, switches (`OneLineRowTests`).
    static func split(room: CGFloat, caption c: CGFloat, content v: CGFloat, contentMost vMost: CGFloat,
                      switches w: CGFloat, switchesLeast wLeast: CGFloat) -> [CGFloat] {
        let vLeast = 0.85 * v   // the most the value's type gives before anything else does
        if c + vLeast + w <= room {
            // All fit (the content taking the rest, as far as it wants it), or with the value's type a little smaller.
            return [c, min(max(room - c - w, 0), max(vMost, v)), w]
        } else if c + vLeast + wLeast <= room {
            // The switches give way (a chip for ANG | SPD) to the value, the caption whole.
            let value = min(v, room - c - wLeast)
            return [c, value, room - c - value]
        }
        // The caption gives way, whole, and the switches stay a chip: whole again in its room, ANG | SPD stood a point
        // taller than a phone-on-its-side line at a big Text Size (the alignment audit).
        return [0, max(room - wLeast, 0), wLeast]
    }
}

extension TileFrame where Accessory == EmptyView {
    init(caption: String, oneLineBelow: CGFloat = Theme.oneLineBelow, valueWins: Bool = false,
         @ViewBuilder main: @escaping (_ oneLine: Bool, _ size: CGSize) -> Main) {
        self.init(caption: caption, oneLineBelow: oneLineBelow, valueWins: valueWins, main: main,
                  accessory: { _ in EmptyView() })
    }
}

/// A value with the chevron at the trailing edge when it can be picked, filling the space it's given so the
/// whole area is the tap target.
struct ValueLine: View {
    var text: String
    var size: CGFloat
    var showsChevron: Bool
    var color: Color = Theme.text
    /// Where the value sits in its space: centered under the caption, whatever the tile's height.
    var alignment: Alignment = .leading
    /// Allow the value to wrap onto a second line rather than shrink. Use for tiles whose values can be long
    /// (codec, bitrate, resolution, de-squeeze, LUT, WB mode). In one-line compact mode this must stay false.
    var multiline: Bool = false
    /// A smaller, muted second part after the value: bitrate shows "240M" at the tile's size and "4:2:2 10bit" after it,
    /// so its headline matches the codec beside it instead of the whole string shrinking to fit.
    var detail: String? = nil
    /// The detail is a label, not a value ("800 BASE"): caption type on the value's baseline, whatever the value's size.
    var detailIsCaption = false
    /// The camera has this value and won't take it from here: a lock where the chevron would be (`PickerValue`).
    var setOnCamera = false
    @Environment(\.tileScale) private var s
    @Environment(\.shortLine) private var shortLine

    var body: some View {
        // The value takes the width (a flexible frame, not a Spacer beside it: an HStack splits room between a Spacer
        // and text, which shrank "Off" to "O…"), the chevron rides on the value's line wherever the value sits.
        HStack(spacing: 4 * s) {
            // Wrapping breaks at spaces only: "XAVC S-I 4K" broke as "XAVC S-" / "I 4K" (word joiners hold the hyphen).
            (Text(verbatim: multiline ? text.replacingOccurrences(of: "-", with: "\u{2060}-\u{2060}") : text)
                .font(Theme.value(size)).foregroundColor(color)
             + (detailIsCaption
                ? Text(verbatim: detail.map { "  " + $0.uppercased() } ?? "")
                    .font(Theme.caption(Theme.textScale(s, shortLine: shortLine)))
                    .tracking(Theme.captionTracking(Theme.textScale(s, shortLine: shortLine))).foregroundColor(Theme.secondaryText)
                : Text(verbatim: detail.map { " " + $0 } ?? "")
                    .font(Theme.detail(forValue: size, scale: Theme.textScale(s, shortLine: shortLine))).foregroundColor(Theme.secondaryText)))
                .lineLimit(multiline ? 2 : 1)
                .minimumScaleFactor(multiline ? 0.7 : (size > 28 * s ? 0.35 : 0.5))
                .audited(.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Chevron()
            } else if setOnCamera {
                Image(systemName: "lock.fill")
                    .font(Theme.lockGlyph(Theme.textScale(s, shortLine: shortLine)))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .accessibilityHint(setOnCamera ? "Set on the camera" : "")
    }
}

/// A picker tile's value: the current option, the camera's options behind it. Nothing to pick → grayed, no chevron.
struct PickerValue<Option: Hashable>: View {
    var text: String
    var size: CGFloat
    var options: [Option]
    var title: (Option) -> String
    var isLive: Bool
    var color: Color = Theme.text
    var alignment: Alignment = .leading
    var extra: MenuExtra? = nil
    /// Pass true (with oneLine = false) for tiles whose values can exceed one line at the tile's type size:
    /// codec, bitrate, resolution, de-squeeze, LUT, WB. Keeps same-size tiles at the same type size.
    var multiline: Bool = false
    var detail: String? = nil
    var detailIsCaption = false
    var onSelect: (Option) -> Void
    @Environment(\.cameraIsControllable) private var controllable

    var body: some View {
        // Connected, a value with nothing to pick is one the camera has and won't take from here (a mode, its menu):
        // at full strength with a lock, as it's the camera's real setting; grayed, it would read as broken or stale.
        // Offline, it is stale, and grays.
        let setOnCamera = !isLive && controllable && text != "—"
        // Read out as it's shown, detail and all ("800, base"; "120, to 23.98"): the option's title alone dropped the
        // detail, and gave nothing where the value shown is only part of one (the bitrate's "240M").
        let spoken = [text, detail?.replacingOccurrences(of: "→", with: "to")].compactMap { $0 }.joined(separator: ", ")
        // The option the tile shows is the one the camera has (a pending pick shows as itself until it's confirmed).
        ChoiceMenu(options: options, title: title, isEnabled: isLive, current: options.first { title($0) == text },
                   onSelect: onSelect, extra: extra, spokenValue: spoken) { live in
            ValueLine(text: text, size: size, showsChevron: live,
                      color: live || setOnCamera ? color : Theme.secondaryText,
                      alignment: alignment, multiline: multiline, detail: detail, detailIsCaption: detailIsCaption,
                      setOnCamera: setOnCamera && !live)
        }
    }
}

/// A password field with an eye button that shows what's typed.
/// It goes back to dots whenever the field is rebuilt, so a revealed password doesn't stay on screen.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    var prompt: Text? = nil
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(title, text: $text, prompt: prompt)
                } else {
                    SecureField(title, text: $text, prompt: prompt)
                }
            }
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
    }
}
