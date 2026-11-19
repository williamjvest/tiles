import SwiftUI
import CameraCore

// MARK: - Monitoring and lens

/// An on/off camera setting shown as a labeled button (Look, False Color, Color Bars, Sensor Flip).
/// When the setting is on, the entire tile fill shifts to `Theme.engaged` (muted indigo) and the label
/// is white: one deliberate system for every whole-tile toggle. `RecordTile` uses the same anatomy —
/// tile fill signals state — but `Theme.recording` red is purpose-specific to the record action.
struct ToggleTile: View {
    let camera: CameraController
    let title: String
    /// The one output the tile switches (a Blackmagic camera's "SDI"), named under the title; nil for every output.
    var output: String? = nil
    /// Why it can't be switched, under the title where there's no output to name: "Assign a button" (an FX5's False
    /// Color with no button set to it).
    var note: String? = nil
    let choice: Choice<Bool>?
    let command: (Bool) -> CameraCommand
    /// Several commands per tap (a monitoring switch set to several outputs); nil sends `command`.
    var commands: ((Bool) -> [CameraCommand])? = nil
    var tally: Bool = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let engaged = choice?.shown == true
        // Read-only (the camera won't change it now, e.g. every output on clean feed): the title grays, as a value does.
        let readOnly = choice?.isWritable == false
        Tile(tint: tally ? Theme.recording : camera.slot.tint,
             fill: engaged ? Theme.engaged : Theme.tile,
             isEnabled: choice != nil) {
            GeometryReader { geo in
                Button {
                    if let choice {
                        if let commands { commands(!choice.shown).forEach { camera.send($0) } } else { camera.send(command(!choice.shown)) }
                    }
                } label: {
                    label(short: geo.size.height < 34 * s, engaged: engaged, readOnly: readOnly)
                        .padding(.horizontal, Theme.inset * s)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!camera.state.connection.isControllable || choice?.isWritable != true)
                .accessibilityValue(engaged ? "On" : "Off")
                .accessibilityHint(note ?? "")
            }
        }
    }

    /// The title, and the output under it (beside it in a short tile), so two tiles for one overlay tell apart. On the
    /// engaged fill the output is white like the title: gray on indigo barely read.
    @ViewBuilder
    private func label(short: Bool, engaged: Bool, readOnly: Bool) -> some View {
        // One line where it fits, two (at the space) where it doesn't; short tiles (stacked half-rows) get one line, so
        // text can't clip. Never a line break in the title: "Frame\nGuides" broke where "False Color" didn't, in tiles
        // of one width.
        // A light beside the name, lit when it's on: with the gray fill alone, a switch that's off looks like a tile that
        // only says something, and one that's on like one that's selected.
        let light = Circle()
            .fill(engaged ? (readOnly ? Theme.secondaryText : Theme.text) : Color.clear)
            .overlay(Circle().strokeBorder(engaged && !readOnly ? Theme.text : Theme.secondaryText, lineWidth: 1.5 * s))
            .frame(width: 8 * s, height: 8 * s)
            .accessibilityHidden(true)
        let name = HStack(spacing: 6 * s) {
            light
            Text(title)
                .font(Theme.buttonLabel(short: short, scale: s))
                .multilineTextAlignment(.center)
                .lineLimit(short ? 1 : 2)
                .minimumScaleFactor(0.5)
                .foregroundStyle(readOnly ? Theme.secondaryText : Theme.text)
        }
        if let output = output ?? note {
            let target = Text(verbatim: output.uppercased())
                .font(Theme.caption(s))
                .tracking(Theme.captionTracking(s))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(engaged && !readOnly ? Theme.text : Theme.secondaryText)
            if short {
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) { name; target }
            } else {
                VStack(spacing: 3 * s) { name; target }
            }
        } else {
            name
        }
    }
}

/// What a VENICE's frame line set shows of its user frame lines. A tap steps on as the camera's own User Frame Disp.
/// button does, both, the first, the second, none and round again (on set they're cycled from a hot button); a long
/// press lists them to pick one. Lit while any is shown.
struct UserFrameTile: View {
    let camera: CameraController
    let set: FrameLineSet
    @Environment(\.tileScale) private var s

    var body: some View {
        let choice = set == .a ? camera.state.userFrameLinesA : camera.state.userFrameLinesB
        let live = camera.state.connection.isControllable && choice?.isWritable == true
        let shown = choice.map { $0.shown != UserFrameLines.off } ?? false
        Tile(tint: camera.slot.tint, fill: shown ? Theme.engaged : Theme.tile, isEnabled: choice != nil) {
            Button {
                if let choice, let next = UserFrameLines.next(after: choice.shown, in: choice.options) {
                    camera.send(.setUserFrameLines(set, next))
                }
            } label: {
                TileFrame(caption: "User Frame \(set.rawValue)", valueWins: true) { oneLine, size in
                    ValueLine(text: choice?.shown ?? "—",
                              size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                              showsChevron: false, color: live ? Theme.text : Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!live)
            .contextMenu {
                if live {
                    ForEach(choice?.options ?? [], id: \.self) { option in
                        Button(option) { camera.send(.setUserFrameLines(set, option)) }
                    }
                }
            }
            .accessibilityLabel("User Frame \(set.rawValue)")
            .accessibilityValue(choice?.shown ?? "")
            .accessibilityHint("Steps to the next, as the camera's button does. Touch and hold to pick one.")
        }
    }
}

/// Opens the monitoring outputs in a window (`MonitoringView`): what each one (a Blackmagic camera's LCD, USB-C monitors
/// and SDI) shows, the zebra level and the guide ratio. A button with ›, not a readout with ⌄: a line per output didn't
/// read at a glance, and it opens a window, not a menu.
struct MonitoringTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet

    var body: some View {
        let hasOutputs = camera.state.monitoring?.outputs.isEmpty == false
        Tile(tint: camera.slot.tint, isEnabled: hasOutputs) {
            Button { presentTileSheet(.monitoring(camera.id)) } label: {
                WindowButtonLabel(title: "Monitoring Options")
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable || !hasOutputs)
        }
    }
}

/// The camera's own buttons, in a window (`CameraMenuView`): its menu worked from a monitor on its output, without its
/// screen. Offered where the camera lets them be pressed (`CameraState.cameraButtons`, the BURANO).
struct CameraMenuTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet

    var body: some View {
        let has = !camera.state.cameraButtons.isEmpty
        Tile(tint: camera.slot.tint, isEnabled: has) {
            Button { presentTileSheet(.cameraMenu(camera.id)) } label: {
                WindowButtonLabel(title: "Camera Menu")
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable || !has)
        }
    }
}

/// A tile that is one button opening a window: its name centered, as a toggle tile's, and › after it.
/// The › aligns on firstTextBaseline with the title so it sits level with the text at any tile height.
struct WindowButtonLabel: View {
    var title: String
    @Environment(\.tileScale) private var s

    var body: some View {
        GeometryReader { geo in
            let short = geo.size.height < 34 * s
            HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                Text(title)
                    .font(Theme.buttonLabel(short: short, scale: s))
                    .multilineTextAlignment(.center)
                    .lineLimit(short ? 1 : 2)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Theme.text)
                SheetChevron()
            }
            .padding(.horizontal, Theme.inset * s)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
    }
}

/// Each monitoring output's overlays, a switch each, and the zebra level and frame guide ratio they share. Every change
/// is the camera's to confirm.
struct MonitoringView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let monitoring = camera.state.monitoring
        let live = camera.state.connection.isControllable
        NavigationStack {
            Form {
                ForEach(monitoring?.outputs ?? []) { output in
                    Section {
                        // A switch that makes this output follow another by cloning it (an ALEXA Mini's SDI 2: clone
                        // SDI 1). Shown first so the user can turn off the clone before trying to set SDI 2.
                        if let sw = output.sameAsSwitch {
                            let leaderName = output.follows.flatMap { id in monitoring?.outputs.first { $0.id == id }?.name } ?? output.follows ?? "SDI 1"
                            Toggle("Same as \(leaderName)", isOn: Binding(get: { sw.shown },
                                                                          set: { camera.send(.setOutputFollows($0, output: output.id)) }))
                                .disabled(!live || !sw.isWritable)
                        }
                        ForEach(MonitorOverlay.allCases.filter { output.overlays[$0] != nil }, id: \.self) { overlay in
                            // Grayed while this output's clean feed hides it.
                            let choice = output.setting(overlay)
                            Toggle(overlay.title, isOn: Binding(get: { choice?.shown == true },
                                                                set: { camera.send(.setMonitorOverlay(overlay, $0, output: output.id)) }))
                                .disabled(!live || choice?.isWritable != true)
                        }
                        // Which frame line set it shows: a VENICE's Line A or Line B.
                        if let lines = output.frameLines {
                            Picker("Frame Lines", selection: Binding(get: { lines.shown },
                                                                     set: { camera.send(.setFrameLineSet($0, output: output.id)) })) {
                                ForEach(lines.options, id: \.self) { Text($0.title).tag($0) }
                            }
                            .disabled(!live || !lines.isWritable)
                        }
                        // What its status text shows: SDI's "for" the director or the cinematographer, as the camera
                        // puts it; the others' meters or codec and resolution.
                        if let shows = output.statusTextShows {
                            Picker(shows.value.pair.contains(.director) ? "Status Text For" : "Status Text Shows",
                                   selection: Binding(get: { shows.shown },
                                                      set: { camera.send(.setStatusTextContent($0, output: output.id)) })) {
                                ForEach(shows.options, id: \.self) { Text($0.title).tag($0) }
                            }
                            .disabled(!live || !shows.isWritable)
                        }
                    } header: {
                        Text(output.name)
                    } footer: {
                        // The camera links this output to another (a VENICE's "Same as Monitor"): set there.
                        if let id = output.follows {
                            let leader = monitoring?.outputs.first { $0.id == id }?.name ?? id
                            FooterText("Same as \(leader): its frame lines and overlays are set on \(leader).")
                        }
                    }
                }
                if monitoring?.zebraLevel != nil || monitoring?.frameGuideRatio != nil {
                    Section {
                        if let level = monitoring?.zebraLevel {
                            Picker("Zebra Level", selection: Binding(get: { level.shown }, set: { camera.send(.setZebraLevel($0)) })) {
                                ForEach(level.options, id: \.self) { Text(verbatim: "\($0)%").tag($0) }
                            }
                            .disabled(!live || !level.isWritable)
                        }
                        if let ratio = monitoring?.frameGuideRatio {
                            Picker("Frame Guides", selection: Binding(get: { ratio.shown }, set: { camera.send(.setFrameGuideRatio($0)) })) {
                                ForEach(ratio.options, id: \.self) { Text(verbatim: $0).tag($0) }
                            }
                            .disabled(!live || !ratio.isWritable)
                        }
                    } footer: {
                        FooterText("Clean Feed keeps every overlay but the LUT off its output, so they're dimmed while it's on.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Monitoring Options")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// The top bar's padlock as a tile, so the lock is on the page: one lock, so either of them locks every tile and
/// either unlocks them. The one tile that still takes a tap while they're locked (`ignoresLock`). Locked, it fills
/// `Theme.locked`, the top bar padlock's yellow, and its padlock closes: in the engaged gray it didn't stand out on a
/// page the lock had grayed. The app's, not the camera's: the camera only gives it a color.
struct LockTile: View {
    let camera: CameraController
    @Environment(\.controlsLocked) private var locked
    @Environment(\.toggleControlsLock) private var toggleLock
    @Environment(\.tileScale) private var s

    var body: some View {
        Tile(tint: camera.slot.tint, fill: locked ? Theme.locked : Theme.tile, ignoresLock: true) {
            GeometryReader { geo in
                let short = geo.size.height < 34 * s
                Button { toggleLock() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                        Image(systemName: locked ? "lock.fill" : "lock.open")
                            .font(Theme.symbol((short ? 11 : 14) * s))
                        Text("Lock")
                            .font(Theme.buttonLabel(short: short, scale: s))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .foregroundStyle(locked ? Theme.lockedText : Theme.text)
                    .padding(.horizontal, Theme.inset * s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lock")
                .accessibilityValue(locked ? "Locked" : "Unlocked")
            }
        }
    }
}

/// The monitor LUT: which LUT, whether it's on, and a one-tap False Color swap. Both switches sit in the header
/// (where every tile keeps its mode switches), lit when on; the LUT name is the picker underneath.
/// - ON / OFF: the camera's monitor LUT switch, only for a camera that reports it.
/// - FALSE COLOR: only when one of the camera's LUTs is a false color LUT. It remembers the LUT you were on, so
///   a second tap puts it back.
struct LUTTile: View {
    let camera: CameraController
    /// Its on/off switch: off where the page has the LUT on/off tile for this camera (`WidgetView.lutSwitch`).
    var showsLookSwitch = true
    @Environment(\.presentTileSheet) private var presentTileSheet
    @Environment(\.lutNames) private var lutNames
    @Environment(\.tileScale) private var s

    /// A false color LUT: "False Color" in its name, or FC as its own word ("GK_SLOG3_Log_FC"). Not on a camera with
    /// its own false color whose look reaches every output (VENICE: `CameraState.offersFalseColorLUTSwap`).
    static func falseColorOption(in state: CameraState) -> String? {
        guard state.offersFalseColorLUTSwap else { return nil }
        return state.lut?.options.first(where: isFalseColorLUT)
    }

    private var falseColorOption: String? { Self.falseColorOption(in: camera.state) }

    private var isFalseColor: Bool {
        guard let fc = falseColorOption else { return false }
        return camera.state.lut?.shown == fc
    }

    private var look: Choice<Bool>? { showsLookSwitch ? camera.state.look : nil }

    var body: some View {
        let lut = camera.state.lut
        let look = self.look
        let controllable = camera.state.connection.isControllable
        let liveLUT = controllable && lut?.isWritable == true
        let liveLook = controllable && look?.isWritable == true
        let spec = WidgetKind.lut.spec
        Tile(tint: camera.slot.tint, isEnabled: lut != nil || camera.state.look != nil) {
            // An ARRI camera loads looks (ARRI Look Files), and calls them that. Its switch is the monitor's LUT on a
            // Sony body, every output's on a camera with outputs of its own (VENICE, ARRI, Blackmagic).
            TileFrame(caption: camera.state.make == .arri ? "Look" : "LUT",
                      switchCaption: falseColorOption == nil && look == nil ? nil
                          : camera.state.lutIsOnOutputs ? "Outputs" : "Monitor",
                      oneLineBelow: falseColorOption == nil && look == nil ? Theme.oneLineBelow : (spec.oneLineBelow ?? 58),
                      trailingFrom: spec.trailingFrom) { oneLine, size in
                // The same picker as every tile; a camera that can load LUTs gets "Load LUT onto Camera…" after them.
                PickerValue(text: lut.map { lutTitle($0.shown, names: lutNames) } ?? "—",
                            size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: lut?.options ?? [], title: { lutTitle($0, names: lutNames) }, isLive: liveLUT,
                            extra: camera.lutImporter == nil ? nil
                                : MenuExtra(title: "Load LUT onto Camera…", systemImage: "square.and.arrow.down") {
                                    presentTileSheet(.lutImport(camera.id))
                                },
                            multiline: !oneLine,
                            // While the LUT goes into the recording (an FX6's LUT in Rec), picking one changes what's
                            // recorded: the tile says so.
                            detail: camera.state.recordedLUT?.shown == true ? "in rec" : nil, detailIsCaption: true) {
                    camera.send(.setLUT($0))
                }
            } accessory: { placement in
                // In their own column on the right, at a size to hit. A tile too short for the column's caption
                // and full-size switches goes to one line: caption, LUT, then the switches, still full height, "FC" to leave the name room.
                switch placement {
                case .inline:
                    lutSwitches(falseColorTitle: "FC", height: 28, liveLUT: liveLUT, liveLook: liveLook)
                default:
                    let height: CGFloat = placement == .header ? 20 : 30
                    ViewThatFits(in: .horizontal) {
                        lutSwitches(falseColorTitle: "False Color", height: height, liveLUT: liveLUT, liveLook: liveLook)
                        lutSwitches(falseColorTitle: "FC", height: height, liveLUT: liveLUT, liveLook: liveLook)
                    }
                }
            }
        }
    }

    private func lutSwitches(falseColorTitle: String, height: CGFloat, liveLUT: Bool, liveLook: Bool) -> some View {
        HStack(spacing: 6 * s) {
            if let fc = falseColorOption {
                PillToggle(title: falseColorTitle, lit: isFalseColor, isEnabled: liveLUT, height: height) { toggleFalseColor(fc) }
            }
            if let look {
                PillToggle(title: look.shown ? "On" : "Off", lit: look.shown, isEnabled: liveLook, height: height) {
                    camera.send(.setLook(!look.shown))
                }
            }
        }
    }

    private func toggleFalseColor(_ falseColor: String) {
        let lut = camera.state.lut
        if isFalseColor {
            let restore = camera.lutBeforeFalseColor ?? lut?.options.first { !isFalseColorLUT($0) }
            if let restore { camera.send(.setLUT(restore)) }
        } else {
            camera.send(.setLUT(falseColor))
        }
    }
}

/// AF / MF. Shows whatever options the camera reports (e.g. "AF-C", "MF").
struct FocusModeTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let focus = camera.state.focusMode
        let live = camera.state.connection.isControllable && focus?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: focus != nil) {
            // A full-size switch needs ~60pt under a caption; shorter tiles (the iPhone column) put it beside the caption.
            TileFrame(caption: "Focus", oneLineBelow: WidgetKind.focusMode.spec.oneLineBelow ?? 60) { oneLine, size in
                // Full size where it fits; on a squeezed row, as tall as the tile allows (it overflowed on an iPhone).
                MiniSegmented(options: focus?.options ?? [], selection: focus?.shown, label: { $0 }, isEnabled: live,
                              segmentHeight: oneLine ? max(16, min(24, size.height / s - 16)) : nil) {
                    camera.send(.setFocusMode($0))
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// What one output's status text shows (Blackmagic's "Display status text for" on SDI; meters or codec and resolution on
/// the LCD and USB-C), as a two-way switch under the output's name. Its output is picked in edit mode, SDI to start.
struct StatusTextContentTile: View {
    let camera: CameraController
    var output: TileOutput?
    @Environment(\.tileScale) private var s

    var body: some View {
        // A tile from before its output was picked shows the one a new tile would start on.
        let id = output?.id ?? camera.state.monitoring?.defaultOutput(for: .statusTextContent)?.id
        let shown = camera.state.monitoring?.outputs.first { $0.id == id }
        let choice = shown?.statusTextShows
        let live = camera.state.connection.isControllable && choice?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: choice != nil) {
            TileFrame(caption: [shown?.name ?? output?.name, "Status Text"].compactMap { $0 }.joined(separator: " "),
                      oneLineBelow: WidgetKind.statusTextContent.spec.oneLineBelow ?? 60) { oneLine, size in
                // "Cinematographer" where it fits, "Cine" where it doesn't.
                ViewThatFits(in: .horizontal) {
                    contentSwitch(choice, id: id, live: live, oneLine: oneLine, size: size, label: \.title)
                    contentSwitch(choice, id: id, live: live, oneLine: oneLine, size: size, label: \.shortTitle)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

extension StatusTextContentTile {
    private func contentSwitch(_ choice: Choice<StatusTextContent>?, id: String?, live: Bool, oneLine: Bool, size: CGSize,
                               label: @escaping (StatusTextContent) -> String) -> some View {
        MiniSegmented(options: choice?.options ?? [], selection: choice?.shown, label: label, isEnabled: live,
                      segmentHeight: oneLine ? max(16, min(24, size.height / s - 16)) : nil) {
            if let id { camera.send(.setStatusTextContent($0, output: id)) }
        }
    }
}
