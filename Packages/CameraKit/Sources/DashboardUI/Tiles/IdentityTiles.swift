import SwiftUI
import CameraCore

// One struct per tile. Every tile reads the camera's state and dims itself when the body doesn't report that
// control, rather than guessing.
//
// Captioned tiles share one anatomy (`TileFrame`): caption top left, the tile's mode switches top right, the value
// below at the same inset, a chevron at the trailing edge only when there's something to pick. The identity tiles
// (name, status, timecode) and the two hero controls (REC, shutter dial) carry no caption.

// MARK: - Identity

/// Timecode where a camera reports it. No Sony body does over PTP 3 (0xD0D3 is only the preset and never moves),
/// so for them this is the take's REC time: counting in red from the take's start, then the last take's length in gray
/// once it stops. HH:MM:SS, no frames: frames would be invented. A take already rolling when Tiles first saw the camera
/// has no start (`CameraController.timeTake`): --:--:--, in red while it rolls, rather than a length made up.
struct TimecodeTile: View {
    let camera: CameraController
    @State private var lastTake = LastTake.none
    private enum LastTake { case none, ran(TimeInterval), unknown }
    private struct Take: Equatable {
        var rolling: Bool
        var started: Date?
    }
    @Environment(\.controlsLocked) private var locked
    @Environment(\.tileScale) private var s

    var body: some View {
        Tile(tint: camera.slot.tint, isReadout: true) {
            TimelineView(.periodic(from: .now, by: camera.state.timecode == nil ? 0.5 : 1.0 / 24.0)) { context in
                GeometryReader { geo in
                    let size = Theme.identitySize(geo.size)
                    let reading = self.reading(at: context.date)
                    HStack(alignment: .capCenter, spacing: 7 * s) {
                        Circle().fill(statusColor).frame(width: 6 * s, height: 6 * s)
                        if camera.state.timecodeShowsDuration?.shown == true {
                            Text("DUR")
                                .font(Theme.caption(s))
                                .tracking(Theme.captionTracking(s))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Text(reading.text)
                            .font(Theme.identity(size))
                            .foregroundStyle(reading.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .capCentered(size, weight: .semibold)
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, Theme.inset * s)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .centerCapCenter)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A camera with its own TC / duration display (VENICE): a tap switches it. Not while the controls are locked:
            // this tap is on the tile's outside, where `Tile` doesn't stop it.
            if !locked, let mode = camera.state.timecodeShowsDuration, mode.isWritable, camera.state.connection.isControllable {
                camera.send(.setTimecodeShowsDuration(!mode.shown))
            }
        }
        .onChange(of: take) { was, now in
            // A take that stopped, or whose link dropped: how long it ran, if Tiles saw it start.
            if let started = was.started, now.started == nil {
                lastTake = .ran(Date().timeIntervalSince(started))
            } else if was.rolling, !now.rolling, was.started == nil {
                lastTake = .unknown
            }
        }
    }

    private var take: Take {
        Take(rolling: camera.state.connection == .connected && camera.state.recording.state == .recording,
             started: camera.state.takeStartedAt)
    }

    /// With the link down, what the camera last said, grayed as a stale value is everywhere else on its page.
    private func reading(at date: Date) -> (text: String, color: Color) {
        let reading = latest(at: date)
        return camera.state.connection == .connected ? reading : (reading.text, Theme.secondaryText)
    }

    private func latest(at date: Date) -> (text: String, color: Color) {
        if let timecode = camera.state.timecode {
            return (timecode.string(at: date), Theme.timecode)
        }
        if let started = camera.state.takeStartedAt {
            return (Self.duration(date.timeIntervalSince(started)), Theme.recording)
        }
        if take.rolling { return (Self.unknownDuration, Theme.recording) }
        switch lastTake {
        case .none: return (Self.duration(0), Theme.secondaryText)
        case .ran(let length): return (Self.duration(length), Theme.secondaryText)
        case .unknown: return (Self.unknownDuration, Theme.secondaryText)
        }
    }

    /// A take's length Tiles can't know: one already rolling when it first saw the camera.
    static let unknownDuration = "--:--:--"

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    private var statusColor: Color {
        switch camera.state.connection {
        case .connected: camera.state.recording.state == .recording ? Theme.recording : Theme.timecode
        case .failed: Theme.recording
        case .awaitingApproval: Theme.legible(.orange)
        default: Theme.secondaryText
        }
    }
}

/// The camera's letter and its model (or what the link is doing), centered: letter in its color, model beside it
/// at 5/8 the size, both centered on one line.
struct LabelTile: View {
    let camera: CameraController
    @State private var showingWhy = false
    @Environment(\.controlsLocked) private var locked
    @Environment(\.tileScale) private var s

    var body: some View {
        Tile(tint: camera.slot.tint, isReadout: true) {
            GeometryReader { geo in
                let size = min(40, Theme.identitySize(geo.size) * 1.25)
                let status = statusText
                HStack(alignment: .capCenter, spacing: max(6, size * 0.3)) {
                    letter(size).capCentered(size, weight: .heavy).layoutPriority(1)
                    if let status {
                        Text(verbatim: status.text)
                            .font(Theme.identity(size * 0.625))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .capCentered(size * 0.625, weight: .semibold)
                        if why != nil {
                            Image(systemName: "info.circle")
                                .font(Theme.symbol(size * 0.45))
                                .foregroundStyle(status.color)
                        }
                    }
                }
                .padding(.horizontal, Theme.inset * s)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .centerCapCenter)
            }
        }
        .contentShape(Rectangle())
        // On the tile's outside, where `Tile` doesn't stop it: not while the controls are locked.
        .onTapGesture { if why != nil, !locked { showingWhy = true } }
        .popover(isPresented: $showingWhy) {
            VStack(alignment: .leading, spacing: 12) {
                Text(why ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect") {
                    camera.reconnectNow()
                    showingWhy = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(why == nil ? "" : "Shows why, and reconnects")
    }

    /// Why the camera isn't connected, behind a tap on the tile's one word: the reason was only in the link menu, and
    /// the tile showed only "Failed". With Reconnect, which tries it now rather than at its next retry.
    private var why: String? {
        switch camera.state.connection {
        case .failed(let reason): reason
        case .disconnected: "Camera \(camera.slot.label) isn't connected."
        default: nil
        }
    }

    private func letter(_ size: CGFloat) -> some View {
        Text(camera.slot.label)
            .font(Theme.letter(size))
            .foregroundStyle(Theme.legible(camera.slot.tint))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var statusText: (text: String, color: Color)? {
        guard camera.state.connection == .connected else { return Self.linkStatus(camera) }
        // What the camera itself warns of (overheating, a card in trouble), in place of its model: as its screen would.
        if let alert = camera.state.alerts.first { return (alert, Theme.recording) }
        guard let model = camera.state.modelName else { return camera.isDemo ? ("demo", Theme.secondaryText) : nil }
        return (camera.isDemo ? "\(model) demo" : model, Theme.secondaryText)
    }

    /// What the link is doing, for a camera that isn't connected (nil when it is), in place of its model: here, and in
    /// the camera switcher on an iPhone, where the other cameras' pages aren't in view.
    static func linkStatus(_ camera: CameraController) -> (text: String, color: Color)? {
        switch camera.state.connection {
        case .connected: return nil
        case .connecting: return ("Connecting", Theme.secondaryText)
        case .awaitingApproval:
            // Bluetooth bonds with the 6-digit code the camera shows, typed into the system's prompt here.
            return (BluetoothCameraAddress.id(in: camera.slot.host) == nil ? "Approve on camera" : "Type the camera's code", Theme.legible(.orange))
        case .fingerprintChanged: return ("Fingerprint changed", Theme.recording)
        case .stale: return ("Resyncing", Theme.secondaryText)
        case .disconnected: return ("Offline", Theme.secondaryText)
        case .failed: return ("Failed", Theme.recording)
        }
    }
}

/// Battery and media at a glance. The readings lay out side by side or stacked, whichever gives the bigger type.
struct StatusTile: View {
    let camera: CameraController
    let tally: Bool
    /// Tap the card reading to switch minutes and hours ("541m" / "9h01").
    @AppStorage("tw.cc.mediaInHours") private var mediaInHours = false
    /// Tap the battery reading to switch percent and volts, on a camera that reports both.
    @AppStorage("tw.cc.batteryInVolts") private var batteryInVolts = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let state = camera.state
        Tile(tint: tally ? Theme.recording : camera.slot.tint,
             isEnabled: state.batteryPercent != nil || state.batteryVolts != nil || state.mediaRemainingMinutes != nil,
             isReadout: true) {
            GeometryReader { geo in
                let width = geo.size.width - 2 * Theme.inset * s
                let height = geo.size.height - 2 * Theme.insetV * s
                // Each reading is an icon and about four characters ("100%", "142m"): ~4.2em wide. Never bigger than
                // the timecode and latency beside it in the identity strip.
                let across = min(height * 0.72, (width - 12 * s) / 2 / 4.2)
                let stacked = min((height - 4 * s) / 2 * 0.72, width / 4.2)
                let size = min(max(across, stacked, 9), Theme.identitySize(geo.size))
                Group {
                    if across >= stacked {
                        HStack(alignment: .capCenter, spacing: 12 * s) {
                            batteryLine(state.batteryPercent, volts: state.batteryVolts, size: size)
                                .capCentered(size, weight: .semibold)
                            mediaLine(state.mediaRemainingMinutes, size: size).capCentered(size, weight: .semibold)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4 * s) {
                            batteryLine(state.batteryPercent, volts: state.batteryVolts, size: size)
                            mediaLine(state.mediaRemainingMinutes, size: size)
                        }
                    }
                }
                .padding(.horizontal, Theme.inset * s)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .centerCapCenter)
            }
        }
    }

    private func batteryLine(_ percent: Int?, volts: Double?, size: CGFloat) -> some View {
        let both = percent != nil && volts != nil
        return Self.batteryReading(percent: percent, volts: volts, minutes: camera.state.batteryMinutes,
                                   source: camera.state.powerSource, inVolts: both && batteryInVolts,
                                   stale: camera.state.connection != .connected, size: size)
            .contentShape(Rectangle())
            .onTapGesture { if both { batteryInVolts.toggle() } }
            .accessibilityAddTraits(both ? .isButton : [])
    }

    /// Battery label used by `StatusTile`, `BatteryTile`. `inVolts`: show volts instead of percent when both exist.
    /// `stale`: the link is down, so it's what the camera last said, grayed.
    /// `source`: what's powering the camera where it isn't simply its battery ("USB", "DC", "AC"…), after the reading,
    /// or alone with a plug where there's no reading (an FX5 on USB-C read 0%, a dummy battery reads nothing).
    static func batteryReading(percent: Int?, volts: Double?, minutes: Int? = nil, source: String? = nil, inVolts: Bool,
                               stale: Bool, size: CGFloat) -> some View {
        // As the camera's display: a percentage, else minutes where it's set to them, else volts.
        let value = inVolts ? volts.map(voltsText) : percent.map { "\($0)%" } ?? minutes.map { "\($0) min" } ?? volts.map(voltsText)
        let symbol = value == nil && source != nil ? "powerplug" : batterySymbol(percent)
        let label = { (text: String) in
            Label(text, systemImage: symbol)
                .foregroundStyle(stale ? Theme.secondaryText : (percent ?? 100) <= 15 ? Theme.recording : Theme.text)
                .font(Theme.identity(size))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        // The source after the reading where it fits; a tight tile keeps the reading whole ("0% USB" was cut to "0…").
        let full = [value, source].compactMap { $0 }.joined(separator: " ")
        return ViewThatFits(in: .horizontal) {
            label(full.isEmpty ? "—" : full)
            label(value ?? source ?? "—")
        }
    }


    static func voltsText(_ volts: Double) -> String { String(format: "%.1fV", volts) }

    private func mediaLine(_ minutes: Int?, size: CGFloat) -> some View {
        Self.mediaReading(minutes: minutes, inHours: mediaInHours, stale: camera.state.connection != .connected, size: size)
            .contentShape(Rectangle())
            .onTapGesture { mediaInHours.toggle() }
    }

    /// Media label used by `StatusTile`, `MediaTile`. `stale`: the link is down, so it's what the camera last said, grayed.
    static func mediaReading(minutes: Int?, inHours: Bool, stale: Bool, size: CGFloat) -> some View {
        Label(minutes.map { mediaText($0, inHours: inHours) } ?? "—", systemImage: "sdcard")
            .foregroundStyle(stale ? Theme.secondaryText : (minutes ?? 999) <= 10 ? Theme.recording : Theme.text)
            .font(Theme.identity(size))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    /// Card time left as minutes ("541m") or hours and minutes ("9h01").
    static func mediaText(_ minutes: Int, inHours: Bool) -> String {
        inHours ? "\(minutes / 60)h" + String(format: "%02d", minutes % 60) : "\(minutes)m"
    }

    static func batterySymbol(_ percent: Int?) -> String {
        switch percent ?? 100 {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Battery percentage as its own tile. Caption "Battery" with the reading when there's room (like `LatencyTile`),
/// otherwise the icon and reading alone. Percent by default; volts when that's all the camera reports, or on tap
/// when it reports both (`@AppStorage("tw.cc.batteryInVolts")`). Red at 15 % or less. Battery symbol tracks percent.
struct BatteryTile: View {
    let camera: CameraController
    let tally: Bool
    @AppStorage("tw.cc.batteryInVolts") private var batteryInVolts = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let state = camera.state
        let both = state.batteryPercent != nil && state.batteryVolts != nil
        Tile(tint: tally ? Theme.recording : camera.slot.tint,
             isEnabled: state.batteryPercent != nil || state.batteryVolts != nil || state.batteryMinutes != nil
                || state.powerSource != nil,
             isReadout: true) {
            TileFrame(caption: "Battery") { _, size in
                StatusTile.batteryReading(
                    percent: state.batteryPercent, volts: state.batteryVolts, minutes: state.batteryMinutes,
                    source: state.powerSource,
                    inVolts: both && batteryInVolts, stale: state.connection != .connected,
                    size: Theme.valueSize(oneLine: true, height: size.height, max: 28, scale: s)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if both { batteryInVolts.toggle() } }
                .accessibilityAddTraits(both ? .isButton : [])
            }
        }
    }
}

/// Card remaining time as its own tile. Caption "Media" with the reading when there's room (like `LatencyTile`),
/// otherwise the icon and reading alone. Minutes by default; hours + minutes on tap
/// (`@AppStorage("tw.cc.mediaInHours")`). Red at 10 minutes or less.
struct MediaTile: View {
    let camera: CameraController
    let tally: Bool
    @AppStorage("tw.cc.mediaInHours") private var mediaInHours = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let state = camera.state
        Tile(tint: tally ? Theme.recording : camera.slot.tint,
             isEnabled: state.mediaRemainingMinutes != nil,
             isReadout: true) {
            TileFrame(caption: "Media") { _, size in
                StatusTile.mediaReading(
                    minutes: state.mediaRemainingMinutes, inHours: mediaInHours, stale: state.connection != .connected,
                    size: Theme.valueSize(oneLine: true, height: size.height, max: 28, scale: s)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { mediaInHours.toggle() }
            }
        }
    }
}

/// Round trip to the camera, so a struggling link shows before controls start lagging. Captioned and
/// left-aligned (same anatomy as HaLow): "LATENCY" caption, the icon and ms value below it. The icon is
/// kept: it distinguishes latency from a plain number at a glance, matching HaLow's visual language.
/// Color runs green → yellow → red by latency health, like HaLow's signal quality color.
struct LatencyTile: View {
    let camera: CameraController
    /// This device reaches its cameras over HaLow (its node answers): graded on HaLow's scale (`LatencyGrade`).
    var overHaLow = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let ms = camera.state.latencyMilliseconds
        let color = LatencyGrade.grade(ms ?? 0, overHaLow: overHaLow).color
        Tile(tint: camera.slot.tint, isEnabled: ms != nil, isReadout: true) {
            GeometryReader { geo in
                let reading = { (size: CGFloat) in
                    Label(ms.map { "\($0) ms" } ?? "—", systemImage: "dot.radiowaves.left.and.right")
                        .font(Theme.value(size))
                        .foregroundStyle(ms == nil ? Theme.secondaryText : color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .audited(.value)
                }
                let oneLine = geo.size.height < (Theme.oneLineBelow + Theme.captionRowGrowth) * s
                // The caption is wider at Text Size's bigger type: it needs that much more room beside the reading.
                if oneLine, geo.size.width < (WidgetKind.latency.spec.captionFrom ?? 0) * s * Theme.textBump {
                    // Too narrow for the caption beside the reading: the icon says what it is.
                    reading(Theme.valueSize(oneLine: true, height: geo.size.height, max: 28, scale: s))
                        .padding(.horizontal, Theme.inset * s)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                } else {
                    TileFrame(caption: "Latency") { oneLine, size in
                        reading(Theme.valueSize(oneLine: oneLine, height: size.height, max: 28, scale: s))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Clip naming: the name the camera will give the next clip, then the title, camera ID and reel that go into it, as
/// far as the camera reports them (a Blackmagic camera doesn't say the next clip's name, only the letter and reel).
/// Where the camera lets them be set, a tap opens them in a window (`ClipNamingView`), so it has › and not ⌄.
struct ClipNameTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet
    @Environment(\.tileScale) private var s

    var body: some View {
        let naming = camera.state.fileNaming
        let editable = camera.state.connection.isControllable && naming != nil
        Tile(tint: camera.slot.tint, isEnabled: camera.state.clipName != nil || naming != nil) {
            let content = TileFrame(caption: "Naming") { oneLine, size in
                let valueSize = Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s)
                HStack(spacing: 4 * s) {
                    // Every part where the tile is wide enough; where it isn't, the next clip's name, or the ID where
                    // the camera doesn't say the name.
                    ViewThatFits(in: .horizontal) {
                        allParts(naming, size: valueSize)
                        shortForm(naming, size: valueSize)
                        // Narrower still, the value alone ("A"), not "…" where its caption was cut short (a PYXIS on a
                        // small phone on its side at the biggest Text Size).
                        nameText(camera.state.clipName ?? naming?.cameraID?.shown ?? "—", size: valueSize)
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if editable { SheetChevron() }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            if editable {
                Button { presentTileSheet(.clipNaming(camera.id)) } label: { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    /// The name, then each part as a caption and its value, at one value size: each part starts an equal column
    /// (`ColumnsRow`), so a wide tile is filled rather than left with a gap before its ›.
    private func allParts(_ naming: FileNaming?, size: CGFloat) -> some View {
        ColumnsRow(spacing: 12 * s) {
            if let name = camera.state.clipName ?? (naming == nil ? "—" : nil) { nameText(name, size: size) }
            if let title = naming?.title { CaptionedValue("Title", title.shown, size: size) }
            if let cameraID = naming?.cameraID { CaptionedValue("ID", cameraID.shown, size: size) }
            if let reel = naming?.reel { CaptionedValue("Reel", String(Int(reel.shown)), size: size) }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func shortForm(_ naming: FileNaming?, size: CGFloat) -> some View {
        if let name = camera.state.clipName {
            nameText(name, size: size).lineLimit(1).minimumScaleFactor(0.5)
        } else if let cameraID = naming?.cameraID {
            CaptionedValue("ID", cameraID.shown, size: size).lineLimit(1)
        } else {
            nameText("—", size: size)
        }
    }

    private func nameText(_ name: String, size: CGFloat) -> some View {
        Text(verbatim: name)
            .font(Theme.value(size))
            .foregroundStyle(Theme.text)
    }
}

/// A camera's clip naming: the next clip's name as the camera reports it, and the title, camera ID and reel that go
/// into it. Each change is the camera's to confirm; the camera's file name format decides which parts the name uses.
struct ClipNamingView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var reel = ""
    @FocusState private var editingTitle: Bool

    var body: some View {
        let naming = camera.state.fileNaming
        let live = camera.state.connection.isControllable
        NavigationStack {
            Form {
                if let clipName = camera.state.clipName {
                    Section {
                        LabeledContent("Next clip") {
                            Text(clipName).font(.body.monospaced()).foregroundStyle(Theme.sheet.text)
                        }
                    } footer: {
                        FooterText("As the camera will name it. Which of the parts below go into the name is the camera's file name format, in its menu.")
                    }
                }
                if let current = naming?.title {
                    Section {
                        LabeledContent("Title") {
                            HStack {
                                TextField("Title", text: $title)
                                    .labelsHidden()
                                    .accessibilityIdentifier("clip-title")
                                    .font(.body.monospaced())
                                    .multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                    .focused($editingTitle)
                                    .submitLabel(.done)
                                    .onSubmit { sendTitle() }
                                if title != current.shown {
                                    Button("Set") { sendTitle() }
                                        .disabled(!FileNaming.isValidTitle(title) || !live || !current.isWritable)
                                }
                            }
                        }
                        .disabled(!live || !current.isWritable)
                    } footer: {
                        FooterText(FileNaming.isValidTitle(title) || title.isEmpty
                                   ? "Up to \(FileNaming.titleLimit) letters, digits, _ and -."
                                   : "Only letters, digits, _ and -, up to \(FileNaming.titleLimit).")
                    }
                }
                if let cameraID = naming?.cameraID {
                    Section {
                        Picker("Camera ID", selection: Binding(get: { cameraID.shown },
                                                               set: { camera.send(.setClipCameraID($0)) })) {
                            ForEach(cameraID.options.isEmpty ? [cameraID.value] : cameraID.options, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(!live || !cameraID.isWritable)
                    } footer: {
                        // Only where the reel can be set: a Blackmagic camera keeps it with the card.
                        if naming?.reel?.isWritable == true { FooterText("A new camera ID starts the reel again at 1.") }
                    }
                }
                if let position = naming?.position {
                    Section {
                        Picker("Camera Position", selection: Binding(get: { position.shown },
                                                                     set: { camera.send(.setClipCameraPosition($0)) })) {
                            ForEach(position.options, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!live || !position.isWritable)
                    } header: {
                        Text("Camera Position")
                    } footer: {
                        FooterText("C, L or R in the clip's metadata.")
                    }
                }
                if let level = naming?.reel, !level.isWritable {
                    Section {
                        LabeledContent("Reel") { Text(verbatim: String(Int(level.value))).font(.body.monospaced()) }
                    } footer: {
                        FooterText("The camera sets the reel.")
                    }
                } else if let level = naming?.reel {
                    Section {
                        HStack {
                            Text("Reel")
                            Spacer()
                            TextField("Reel", text: $reel)
                                .labelsHidden()
                                .accessibilityIdentifier("clip-reel")
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .onSubmit { sendReel(level) }
                            Stepper("", onIncrement: { step(level, by: 1) }, onDecrement: { step(level, by: -1) })
                                .labelsHidden()
                        }
                        .disabled(!live || !level.isWritable)
                    } footer: {
                        FooterText("\(Int(level.range.lowerBound)) to \(Int(level.range.upperBound)).")
                    }
                }
                if let failure = naming?.failure {
                    Section { Text(failure).foregroundStyle(Theme.recording) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clip Naming")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { syncFields() }
            .onChange(of: naming?.title?.value) { _, _ in if !editingTitle { syncFields() } }
            .onChange(of: naming?.reel?.value) { _, value in reel = value.map { String(Int($0)) } ?? reel }
        }
    }

    private func syncFields() {
        title = camera.state.fileNaming?.title?.shown ?? ""
        reel = camera.state.fileNaming?.reel.map { String(Int($0.shown)) } ?? ""
    }

    private func sendTitle() {
        guard FileNaming.isValidTitle(title), title != camera.state.fileNaming?.title?.shown else { return }
        camera.send(.setClipTitle(title))
        editingTitle = false
    }

    private func sendReel(_ level: Level) {
        guard let value = Int(reel) else { return syncFields() }
        let clamped = min(max(Double(value), level.range.lowerBound), level.range.upperBound)
        reel = String(Int(clamped))
        if clamped != level.shown { camera.send(.setClipReel(Int(clamped))) }
    }

    private func step(_ level: Level, by delta: Double) {
        let next = min(max(level.shown + delta, level.range.lowerBound), level.range.upperBound)
        reel = String(Int(next))
        if next != level.shown { camera.send(.setClipReel(Int(next))) }
    }
}

/// How a camera's round trip reads, as the Latency tile's color and the top bar's bars. Over Wi-Fi a Sony property
/// read comes back in tens of milliseconds, and 80 ms is already slow; HaLow's own floor is higher (a ping ~30 ms on
/// the mesh, and the camera's answer is slower to cross it), and Tiles is built to work at 300 ms there
/// (docs/network-budget.md), so on Wi-Fi's scale a HaLow link right beside the camera would read medium or low.
/// Over HaLow the steps sit at 150, 300 and 600 ms. Green is 3 and 4 bars, yellow 2, red 1.
enum LatencyGrade {
    static func grade(_ ms: Int, overHaLow: Bool) -> (bars: Double, color: Color) {
        let (full, good, fair) = overHaLow ? (150, 300, 600) : (50, 80, 200)
        switch ms {
        case ..<full: return (1, Theme.timecode)
        case ..<good: return (0.75, Theme.timecode)
        case ..<fair: return (0.5, Theme.legible(SlotColor.yellow.color))
        default: return (0.25, Theme.recording)
        }
    }
}
