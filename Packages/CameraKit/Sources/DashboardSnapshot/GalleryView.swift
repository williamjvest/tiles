import SwiftUI
import CameraCore
import DashboardUI

// MARK: - Gallery layout constants

/// Canonical tile sizes exercised in the gallery. (label, width, height)
private let tileSizes: [(String, CGFloat, CGFloat)] = [
    ("phone ½ 1u\n180×44", 180, 44),
    ("phone full 1u\n370×48", 370, 48),
    ("phone 2.1u\n180×100", 180, 100),
    ("iPad ½row\n280×66", 280, 66),
    ("iPad 1×4\n280×140", 280, 140),
    ("wide 3×2\n870×66", 870, 66),
]

// MARK: - GalleryView

/// One sheet: every WidgetKind × all canonical tile sizes, plus a state-variants strip.
struct GalleryView: View {
    let fx3: CameraController
    let fx6: CameraController
    /// An FX6 in Custom, which works in dB: the ISO tile becomes Gain, with a Low | High base.
    let fx6Custom: CameraController
    /// An FX5 in Custom, which works in ISO: the ISO tile with a Low | Mid | High base sensitivity.
    let fx5Custom: CameraController
    /// An FX5 in Flexible ISO: three base ISOs, and the LUT tile's three outputs.
    let fx5Flexible: CameraController
    /// A PYXIS 12K: the Blackmagic-only tiles, and the Blackmagic forms of shared ones (`pyxisForms`).
    let pyxis: CameraController
    /// A BURANO: the tiles only it offers (`buranoKinds`).
    let burano: CameraController
    /// A VENICE 2: its user frame lines (`veniceKinds`), and its Audio tile, meters where a PYXIS's has channels.
    let venice: CameraController

    /// WidgetKinds only a Blackmagic camera offers; and Clips, which a demo FX6 hasn't.
    private static let pyxisKinds: Set<WidgetKind> = [.dynamicRange, .monitoring, .zebra, .focusAssist, .frameGuides, .cleanFeed,
                                                      .statusText, .statusTextContent, .lut, .autoFocus, .audio, .clips]
    /// WidgetKinds only a VENICE offers: what its frame line sets show of the user frame lines.
    private static let veniceKinds: Set<WidgetKind> = [.userFrameA, .userFrameB]
    /// Shared kinds a VENICE draws differently: the Audio tile's meters, and Playback's speed (4×) under ◀◀ ▶▶,
    /// which once rode above the row's line unnoticed because no row drew it.
    private static let veniceForms: [WidgetKind] = [.audio, .playback]
    /// Shared kinds an FX6 draws differently: Auto in the ISO tile beside its base and in the Iris tile, and the LUT
    /// tile's Outputs (SDI/HDMI and VF). The rows above draw these from an FX3 or a PYXIS, so no row drew an FX6's.
    private static let fx6Forms: [WidgetKind] = [.iso, .iris, .lut]
    /// Shared kinds a Blackmagic camera draws differently: no next clip name, Live | Review, its WB presets, the base
    /// ISO, "LUT" for its outputs' LUT.
    private static let pyxisForms: [WidgetKind] = [.clipName, .playback, .wbPreset, .iso, .viewAssist, .falseColor, .desqueeze]
    /// Monitoring switches set to one output, which they name under their titles. In this state SDI is on clean feed:
    /// Clean Feed lit, False Color grayed (clean feed hides it), LUT lit (clean feed doesn't).
    private static let outputForms: [WidgetKind] = [.cleanFeed, .falseColor, .viewAssist, .statusText]
    private static let sdi = TileOutput(id: "MainSDI", name: "SDI")
    /// WidgetKinds only a BURANO offers: its ND mode, tally, CALL, color gamut and buttons.
    private static let buranoKinds: Set<WidgetKind> = [.ndMode, .tally, .call, .colorGamut, .cameraMenu]

    /// WidgetKinds that a demo FX3 offers (all others use fx6 for a camera that has them).
    private static let fx3Kinds: Set<WidgetKind> = [
        .timecode, .label, .shutterDial, .shutterValue, .frameRate, .iso,
        .wbPreset, .wbSliders, .iris, .record, .status, .battery, .media, .latency, .format,
        .colorBars, .falseColor, .look, .sensorFlip, .hdmiInfo, .gridLines,
        .codec, .bitrate, .lut, .focusMode, .viewAssist, .haLow, .lock,
    ]

    /// The whole sheet laid out at full size (no ScrollView: a scroll view clipped the sheet to its window).
    /// The last column: each kind at its smallest on the grid, its minimum columns of a phone's half width (180 pt) on its
    /// minimum half-rows at the 17 pt floor Fit to Screen can shrink rows to. Nothing may be cut off there either.
    static var smallestColumn: CGFloat { 2 * 180 + Theme.gap }

    static func smallest(_ kind: WidgetKind) -> CGSize { kind.smallestOnGrid }

    static var canvasSize: CGSize {
        let width = 40 + 130 + tileSizes.reduce(0) { $0 + $1.1 } + CGFloat(tileSizes.count) * 8 + 40 + smallestColumn + 8
        let rows = CGFloat(WidgetKind.allCases.count)
        // Rows (and the PYXIS's), the header, and the state strip (twenty-one variants at up to 100 pt plus spacing, about
        // 2,100 pt), with room to spare: a sheet taller than its canvas gets clipped top and bottom. At 1,500 the strip's
        // last Playback rows were cut off.
        // And rows of their own: an FX6's Gain, an FX5's ISO, LUT, SteadyShot, Imager Mode, Autofocus, False Color,
        // Battery and Label forms, the ND tile's steps.
        let all = rows + CGFloat(pyxisForms.count + outputForms.count + veniceForms.count + fx6Forms.count) + 14
        return CGSize(width: width, height: 300 + all * (140 + 24) + 2400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            gallerySectionTitle("Tile Gallery — every WidgetKind × canonical sizes")
            headerRow
            tileRows
            gallerySectionTitle("Blackmagic (PYXIS 12K) — where its tiles differ")
            ForEach(Self.pyxisForms, id: \.self) { kind in row(kind, camera: pyxis, label: "PYXIS \(kind.title(for: pyxis.state))") }
            ForEach(Self.outputForms, id: \.self) { kind in
                row(kind, camera: pyxis, label: "PYXIS \(kind.title(for: pyxis.state)) on SDI", output: Self.sdi)
            }
            gallerySectionTitle("VENICE 2 — where its tiles differ")
            ForEach(Self.veniceForms, id: \.self) { kind in row(kind, camera: venice, label: "VENICE \(kind.title)") }
            gallerySectionTitle("FX6 — where its tiles differ")
            ForEach(Self.fx6Forms, id: \.self) { kind in row(kind, camera: fx6, label: "FX6 \(kind.title)") }
            row(.iso, camera: fx6Custom, label: "FX6 Gain (Custom)")
            gallerySectionTitle("FX5 — where its tiles differ")
            row(.iso, camera: fx5Custom, label: "FX5 ISO (Custom)")
            row(.iso, camera: fx5Flexible, label: "FX5 ISO (Flexible ISO)")
            row(.lut, camera: fx5Flexible, label: "FX5 LUT")
            row(.steadyShot, camera: fx5Custom, label: "FX5 SteadyShot")
            row(.imagerMode, camera: fx5Custom, label: "FX5 Imager Mode")
            row(.autoFocus, camera: fx5Custom, label: "FX5 Autofocus (AF)")
            row(.autoFocus, camera: fx5Flexible, label: "FX5 Autofocus (MF)")
            row(.falseColor, camera: fx5Custom, label: "FX5 False Color (no button)")
            row(.falseColor, camera: fx5Flexible, label: "FX5 False Color (on)")
            row(.battery, camera: fx5Custom, label: "FX5 Battery (USB)")
            row(.battery, camera: fx5Flexible, label: "FX5 Battery (dummy)")
            row(.label, camera: fx5Custom, label: "FX5 Label (overheating)")
            // An option switched on: the ND tile's − + step buttons, off unless switched (`PageWidget.stepByDefault`).
            row(.ndPreset, camera: fx3, label: "ND with Step − +", showsStep: true)
            Divider().background(Theme.secondaryText)
            gallerySectionTitle("State variants — ISO picker · REC tile · Label tile")
            stateStrip
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Kind")
                .frame(width: 130, alignment: .leading)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .tracking(Theme.captionTracking)
            ForEach(tileSizes, id: \.0) { label, w, _ in
                Text(label)
                    .frame(width: w, alignment: .center)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Text("smallest on the grid\nmin size, 17 pt rows")
                .frame(width: Self.smallestColumn, alignment: .leading)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
        }
    }

    // MARK: - Tile rows

    private var tileRows: some View {
        ForEach(WidgetKind.allCases, id: \.self) { kind in
            row(kind, camera: Self.buranoKinds.contains(kind) ? burano : Self.pyxisKinds.contains(kind) ? pyxis
                    : Self.veniceKinds.contains(kind) ? venice : Self.fx3Kinds.contains(kind) ? fx3 : fx6,
                label: kind.title)
        }
    }

    /// One kind at every canonical size. Each tile is named for the alignment audit by its size.
    private func row(_ kind: WidgetKind, camera: CameraController, label: String, output: TileOutput? = nil,
                     showsStep: Bool = PageWidget.stepByDefault) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .frame(width: 130, alignment: .leading)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            ForEach(tileSizes, id: \.0) { _, w, h in
                WidgetView(kind: kind, camera: camera,
                           dialSwitch: kind == .shutterDial,
                           haLowStats: kind == .haLow ? HaLowNodeStats(address: "192.0.2.1", hostname: "node-1", signalDBm: -68, noiseDBm: -95, phyRateKbps: 3500, mcsIndex: 7, channelWidthMHz: 2, txRetryRatio: 0.03) : nil,
                           haLowNodeState: kind == .haLow ? .polling : nil, output: output, showsStep: showsStep)
                    .frame(width: w, height: h)
                    // Below the tile's smallest size on the grid (its minimum half-rows at the 17 pt floor) a tile
                    // can't fit and isn't checked.
                    .transformEnvironment(\.alignmentAudit) { audit in
                        let floor = CGFloat(kind.minimumSize.h) * 17 + CGFloat(kind.minimumSize.h - 1) * Theme.gap
                        audit = h < floor ? nil : audit.map { "\($0)\(Int(w))×\(Int(h)) " }
                    }
            }
            let smallest = Self.smallest(kind)
            WidgetView(kind: kind, camera: camera, dialSwitch: kind == .shutterDial, output: output, showsStep: showsStep)
                .frame(width: smallest.width, height: smallest.height)
                .transformEnvironment(\.alignmentAudit) { audit in
                    audit = audit.map { "\($0)smallest \(Int(smallest.width))×\(Int(smallest.height)) " }
                }
                .frame(width: Self.smallestColumn, alignment: .leading)
        }
    }

    // MARK: - State strip

    private var stateStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            stateRow("False Color — off (default tile fill)",
                     kind: .falseColor, camera: falseColorOff(), w: 280, h: 66)
            stateRow("False Color — on (engaged: Theme.engaged indigo fill)",
                     kind: .falseColor, camera: falseColorOn(), w: 280, h: 66)
            stateRow("ISO — live (writable, connected)",
                     kind: .iso, camera: fx3, w: 280, h: 100)
            stateRow("ISO — read-only (isWritable: false)",
                     kind: .iso, camera: readOnlyISO(), w: 280, h: 100)
            stateRow("ISO — not reported (nil, opacity 0.28)",
                     kind: .iso, camera: noISO(), w: 280, h: 100)
            stateRow("ISO — pending (choice.pending != nil)",
                     kind: .iso, camera: pendingISO(), w: 280, h: 100)
            stateRow("REC — standby",
                     kind: .record, camera: fx3, w: 180, h: 100)
            stateRow("REC — recording (tally red)",
                     kind: .record, camera: recording(), w: 180, h: 100)
            stateRow("REC — pending/dim (request in flight)",
                     kind: .record, camera: recPending(), w: 180, h: 100)
            stateRow("REC — failed badge",
                     kind: .record, camera: recFailed(), w: 180, h: 100)
            stateRow("REC — failed, with room for why (the reason under the button)",
                     kind: .record, camera: recFailed(), w: 280, h: 220)
            stateRow("ISO — locked (a control greys: Theme.lockedOpacity)",
                     kind: .iso, camera: fx3, w: 280, h: 100, locked: true)
            stateRow("REC — recording, locked (the tally stays bright)",
                     kind: .record, camera: recording(), w: 180, h: 100, locked: true)
            stateRow("Battery / Media — locked (a read-out stays bright)",
                     kind: .status, camera: fx3, w: 280, h: 60, locked: true)
            stateRow("Battery tile — locked (a read-out stays bright)",
                     kind: .battery, camera: fx3, w: 180, h: 44, locked: true)
            stateRow("Media tile — locked (a read-out stays bright)",
                     kind: .media, camera: fx3, w: 180, h: 44, locked: true)
            stateRow("Lock — locked (the padlock's yellow; still takes a tap)",
                     kind: .lock, camera: fx3, w: 180, h: 44, locked: true)
            stateRow("Label — connected demo (\"FX3 demo\")",
                     kind: .label, camera: fx3, w: 280, h: 60)
            stateRow("Label — awaiting approval (orange)",
                     kind: .label, camera: awaitingApproval(), w: 280, h: 60)
            stateRow("Label — fingerprint changed (red)",
                     kind: .label, camera: fingerprintChanged(), w: 280, h: 60)
            stateRow("Label — offline (secondaryText)",
                     kind: .label, camera: offline(), w: 280, h: 60)
            stateRow("Playback — FX3 live (Review to start)",
                     kind: .playback, camera: fx3, w: 280, h: 100)
            stateRow("Playback — FX3 in review",
                     kind: .playback, camera: inReview(), w: 280, h: 100)
            stateRow("Playback — FX3 in review, narrow",
                     kind: .playback, camera: inReview(), w: 180, h: 100)
        }
    }

    private func stateRow(
        _ label: String, kind: WidgetKind, camera: CameraController,
        w: CGFloat, h: CGFloat, locked: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: 340, alignment: .leading)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            WidgetView(kind: kind, camera: camera)
                .frame(width: w, height: h)
                .environment(\.controlsLocked, locked)
                .transformEnvironment(\.alignmentAudit) { audit in audit = audit.map { "\($0)[\(label)] " } }
        }
    }

    // MARK: - State fixtures (each returns a fresh controller with modified state)

    private func withState(_ modify: (inout CameraState) -> Void) -> CameraController {
        var s = fx3.state
        modify(&s)
        return DashboardStore.galleryController(body: .fx3, label: "C", color: .yellow,
                                                backend: GalleryNullBackend(), state: s)
    }

    private func inReview() -> CameraController {
        withState { $0.playback?.inReview = true }
    }

    private func readOnlyISO() -> CameraController {
        withState { $0.iso = Choice(800, options: [800], isWritable: false) }
    }

    private func noISO() -> CameraController {
        withState { $0.iso = nil }
    }

    private func pendingISO() -> CameraController {
        withState { $0.iso = Choice(800, options: [200, 400, 800, 1600, 3200],
                                    isWritable: true, pending: 1600) }
    }

    private func recording() -> CameraController {
        withState {
            $0.recording = RecordingControl(state: .recording)
            $0.takeStartedAt = Date().addingTimeInterval(-42)
        }
    }

    private func recPending() -> CameraController {
        withState { $0.recording = RecordingControl(state: .idle, request: .start) }
    }

    private func recFailed() -> CameraController {
        withState { $0.recording = RecordingControl(state: .idle, failure: RecordingControl.Failure.refused) }
    }

    private func awaitingApproval() -> CameraController {
        withState { $0.connection = .awaitingApproval }
    }

    private func fingerprintChanged() -> CameraController {
        withState { $0.connection = .fingerprintChanged("AA:BB:CC:DD") }
    }

    private func offline() -> CameraController {
        withState { $0.connection = .disconnected }
    }

    private func falseColorOff() -> CameraController {
        withState { $0.falseColor = Choice(false, options: [false, true], isWritable: true) }
    }

    private func falseColorOn() -> CameraController {
        withState { $0.falseColor = Choice(true, options: [false, true], isWritable: true) }
    }
}

// MARK: - Section title helper

private func gallerySectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(Theme.text)
        .padding(.vertical, 4)
}
