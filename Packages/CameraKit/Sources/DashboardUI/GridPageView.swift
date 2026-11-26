import SwiftUI
import CameraCore

/// Draws one tile kind for one camera, with an optional link-chain badge when the tile's
/// control is linked and linking is active on the current page.
public struct WidgetView: View {
    public let kind: WidgetKind
    public let camera: CameraController
    public var isLinked: Bool = false
    /// The shutter dial carries the Angle | Speed switch when its camera has no shutter value tile on the page.
    public var dialSwitch: Bool = false
    /// The LUT tile carries the LUT's on/off switch when its camera has no LUT on/off tile (every output) on the page.
    public var lutSwitch: Bool = true
    /// Stats for the HaLow tile. Passed in from the store so WidgetView stays stateless.
    public var haLowStats: HaLowNodeStats? = nil
    public var haLowNodeState: HaLowNodeState? = nil
    /// Store reference for the inline Live View tile's page-membership gate. Nil in previews/gallery.
    public var store: DashboardStore? = nil
    /// The one output a monitoring switch is set to (`PageWidget.output`); nil for every output.
    public var output: TileOutput? = nil
    /// Every output it's set to (`PageWidget.targets`): several, one, or none for every output.
    public var outputs: [TileOutput] = []
    /// The ND tile's step buttons are on (`PageWidget.stepButtons`).
    public var showsStep: Bool = PageWidget.stepByDefault
    @Environment(\.alignmentAudit) private var audit

    public init(kind: WidgetKind, camera: CameraController, isLinked: Bool = false, dialSwitch: Bool = false,
                haLowStats: HaLowNodeStats? = nil, haLowNodeState: HaLowNodeState? = nil,
                store: DashboardStore? = nil, output: TileOutput? = nil, outputs: [TileOutput]? = nil,
                showsStep: Bool = PageWidget.stepByDefault, lutSwitch: Bool = true) {
        self.showsStep = showsStep
        self.lutSwitch = lutSwitch
        self.kind = kind
        self.camera = camera
        self.isLinked = isLinked
        self.dialSwitch = dialSwitch
        self.haLowStats = haLowStats
        self.haLowNodeState = haLowNodeState
        self.store = store
        self.output = output
        self.outputs = outputs ?? output.map { [$0] } ?? []
    }

    public var body: some View {
        // The alignment audit names each tile by its kind and camera, after whatever placed it.
        tile.environment(\.alignmentAudit, audit.map { "\($0)\(kind.rawValue) \(camera.slot.label)" })
            .environment(\.cameraIsControllable, camera.state.connection.isControllable)
            // Dynamic Text Size: the tile's scale, from its size.
            .modifier(TileScaling(kind: kind, switches: camera.state.hasModeSwitches(kind, ndStep: showsStep)))
            .overlay(alignment: .bottomLeading) {
                if isLinked {
                    Image(systemName: "link")
                        .font(Theme.symbol(9, weight: .bold))
                        .foregroundStyle(Theme.timecode)
                        .padding(4)
                        .background(Theme.chrome.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var tile: some View {
        let tally = camera.state.recording.state == .recording
        switch kind {
        case .timecode: TimecodeTile(camera: camera)
        case .label: LabelTile(camera: camera)
        case .ndPreset: NDPresetTile(camera: camera, showsStep: showsStep)
        case .ndMinus: NDStepTile(camera: camera, delta: -1)
        case .ndPlus: NDStepTile(camera: camera, delta: 1)
        case .shutterDial: ShutterTile(camera: camera, showsMode: dialSwitch)
        case .shutterValue: ShutterValueTile(camera: camera)
        case .frameRate: FrameRateTile(camera: camera, linkedPeers: store?.linkedPeers(of: camera.id, for: .frameRate) ?? [])
        case .iso: ISOTile(camera: camera)
        case .wbPreset: WhiteBalancePresetTile(camera: camera)
        case .wbSliders: WhiteBalanceSlidersTile(camera: camera)
        case .iris: IrisFaderTile(camera: camera)
        case .record: RecordTile(camera: camera)
        case .status: StatusTile(camera: camera, tally: tally)
        case .battery: BatteryTile(camera: camera, tally: tally)
        case .media: MediaTile(camera: camera, tally: tally)
        case .clipName: ClipNameTile(camera: camera)
        case .latency: LatencyTile(camera: camera, overHaLow: haLowNodeState == .polling)
        case .format: FormatTile(camera: camera)
        case .colorBars:
            ToggleTile(camera: camera, title: "Color Bars", choice: camera.state.colorBars, command: { .setColorBars($0) })
        case .falseColor: monitorToggle(.falseColor, title: "False Color", tally: tally)
        // Named as the camera names it: an ARRI's is its Look (the LUT tile beside it says Look; this said LUT).
        case .look, .viewAssist: monitorToggle(.lut, title: WidgetKind.viewAssist.title(for: camera.state), tally: tally)
        case .sensorFlip:
            ToggleTile(camera: camera, title: "Sensor Flip", choice: camera.state.imageFlip, command: { .setImageFlip($0) }, tally: tally)
        case .webGUI: EmptyView()  // gone: a saved one comes off when the setup loads (`webGUIRemoved`)
        case .hdmiInfo:
            ToggleTile(camera: camera, title: "HDMI Info", choice: camera.state.hdmiInfo, command: { .setHDMIInfo($0) }, tally: tally)
        case .gridLines:
            ToggleTile(camera: camera, title: "Grid Lines", choice: camera.state.gridLines, command: { .setGridLines($0) }, tally: tally)
        case .resolution: ResolutionTile(camera: camera)
        case .codec: CodecTile(camera: camera)
        case .bitrate: BitrateTile(camera: camera)
        case .desqueeze: DesqueezeTile(camera: camera)
        case .lut: LUTTile(camera: camera, showsLookSwitch: lutSwitch)
        case .focusMode: FocusModeTile(camera: camera)
        case .haLow: HaLowTile(stats: haLowStats, nodeState: haLowNodeState, tint: camera.slot.tint)
        case .liveView: LiveViewTile(camera: camera, store: store)
        case .liveViewButton: LiveViewTile(camera: camera, store: store, showsPicture: false)
        case .playback: PlaybackTile(camera: camera)
        case .dynamicRange: DynamicRangeTile(camera: camera)
        case .monitoring: MonitoringTile(camera: camera)
        case .zebra: monitorToggle(.zebra, title: "Zebra", tally: tally)
        case .focusAssist: monitorToggle(.focusAssist, title: kind.title(for: camera.state), tally: tally)
        case .frameGuides: monitorToggle(.frameGuides, title: "Frame Guides", tally: tally)
        case .cleanFeed: monitorToggle(.cleanFeed, title: "Clean Feed", tally: tally)
        case .statusText: monitorToggle(.statusText, title: "Status Text", tally: tally)
        case .statusTextContent: StatusTextContentTile(camera: camera, output: output)
        case .lock: LockTile(camera: camera)
        case .ndMode: ChoiceTile(camera: camera, caption: "ND Mode", choice: camera.state.ndMode) { .setNDMode($0) }
        case .tally: ChoiceTile(camera: camera, caption: "Tally", choice: camera.state.tally) { .setTally($0) }
        case .call: ToggleTile(camera: camera, title: "Call", choice: camera.state.call, command: { .setCall($0) }, tally: tally)
        case .colorGamut:
            ChoiceTile(camera: camera, caption: "Color Gamut", choice: camera.state.colorGamut) { .setColorGamut($0) }
        case .cameraMenu: CameraMenuTile(camera: camera)
        case .autoFocus: AutoFocusTile(camera: camera)
        case .grabStill: GrabStillTile(camera: camera)
        case .audio: AudioTile(camera: camera)
        case .userFrameA: UserFrameTile(camera: camera, set: .a)
        case .userFrameB: UserFrameTile(camera: camera, set: .b)
        case .shootingMode: ShootingModeTile(camera: camera)
        case .recordedLUT:
            ToggleTile(camera: camera, title: "LUT in Rec", choice: camera.state.recordedLUT,
                       command: { .setRecordedLUT($0) }, tally: tally)
        case .proxy:
            ToggleTile(camera: camera, title: "Proxy", output: camera.state.proxyStatus, choice: camera.state.proxyRecording,
                       command: { .setProxyRecording($0) }, tally: tally)
        case .ecs: ECSTile(camera: camera)
        case .focusDrive: LensDriveTile(camera: camera, zoom: false)
        case .zoomDrive: LensDriveTile(camera: camera, zoom: true)
        case .assignable: AssignableTile(camera: camera)
        case .steadyShot:
            ChoiceTile(camera: camera, caption: "SteadyShot", choice: camera.state.steadyShot) { .setSteadyShot($0) }
        case .imagerMode:
            ChoiceTile(camera: camera, caption: "Imager", choice: camera.state.imagerMode) { .setImagerMode($0) }
        case .afSettings: AFSettingsTile(camera: camera)
        case .clips: ClipsTile(camera: camera)
        }
    }
}

extension WidgetView {
    /// An overlay on the one output the tile is set to, named under its title, or on every output: lit only when all of
    /// them show it, so a tap turns it on where it's still off (`CameraState.monitorSwitch`).
    fileprivate func monitorToggle(_ overlay: MonitorOverlay, title: String, tally: Bool) -> some View {
        let toggle = camera.state.monitorSwitch(overlay, outputs: outputs.map(\.id))
        let named = camera.state.setsOverlaysPerOutput && !outputs.isEmpty ? Self.outputsName(outputs) : nil
        return ToggleTile(camera: camera, title: title, output: named,
                          note: overlay == .falseColor ? camera.state.falseColorHint : nil,
                          choice: toggle.choice, command: toggle.command, commands: toggle.commands, tally: tally)
    }

    /// How a tile names the outputs it's set to: one by name, two joined, more counted.
    static func outputsName(_ outputs: [TileOutput]) -> String {
        switch outputs.count {
        case 0: "All Outputs"
        case 1: outputs[0].name
        case 2: "\(outputs[0].name) + \(outputs[1].name)"
        default: "\(outputs.count) Outputs"
        }
    }
}

/// Cell geometry for a customized page. Columns are fixed; row height follows the cell width (clamped to a
/// sane aspect), so a layout built on a big landscape iPad doesn't turn into tall slivers in portrait. The
/// page scrolls vertically if it's taller than the screen.
struct GridMetrics {
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let rowHeight: CGFloat
    let gap: CGFloat

    /// `keepRows`: the rows of the page's automatic layout, which always fit the screen, however small, so REC is never
    /// below the fold. Rows past them (tiles someone added) shrink no further than `minRow`, and then the page scrolls.
    /// 17pt keeps a standard tile (two half-rows and the gap) at 42pt.
    /// `fitRows`: how many rows the height is shared between (all of them by default). A page that scrolls passes its
    /// automatic layout's row count, so tiles added below it don't shrink the rest. `extraRows` (edit mode's spare
    /// rows) never count: they're reached by scrolling. Edit mode uses the same metrics, so editing never resizes a tile.
    /// `rowHeight`: a height to keep instead (edit mode keeps the one it opened with while tiles move). `floorRow`: a
    /// height rows never go under, even to fit, so the page scrolls instead.
    init(layout: PageLayout, size: CGSize, gap: CGFloat = Theme.gap, extraRows: Int = 0, minRow: CGFloat = 17,
         keepRows: Int? = nil, fitRows: Int? = nil, rowHeight kept: CGFloat? = nil, floorRow: CGFloat? = nil) {
        columns = layout.columns
        rows = max(layout.rows, 1) + extraRows
        self.gap = gap
        cellWidth = max((size.width - CGFloat(columns - 1) * gap) / CGFloat(columns), 1)
        func fit(_ rows: Int) -> CGFloat {
            let shared = max(min(rows, layout.rows), 1)
            return (size.height - CGFloat(shared - 1) * gap) / CGFloat(shared)
        }
        let floor = min(minRow, fit(keepRows ?? layout.rows))
        // The cap keeps tiles from turning into tall slivers when width is scarce.
        let fitted = min(max(fit(fitRows ?? layout.rows), floor), max(cellWidth * 0.6, floor))
        rowHeight = kept ?? max(fitted, floorRow ?? 0)
    }

    /// A point on the grid (from its top-left) in cells: columns and half-rows, fractions included.
    func cell(at point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x / (cellWidth + gap)), Double(point.y / (rowHeight + gap)))
    }

    func frame(_ widget: PageWidget) -> CGRect {
        frame(x: widget.x, y: widget.y, w: widget.w, h: widget.h)
    }

    func frame(x: Int, y: Int, w: Int, h: Int) -> CGRect {
        CGRect(
            x: CGFloat(x) * (cellWidth + gap),
            y: CGFloat(y) * (rowHeight + gap),
            width: CGFloat(w) * cellWidth + CGFloat(w - 1) * gap,
            height: CGFloat(h) * rowHeight + CGFloat(h - 1) * gap
        )
    }

    var contentHeight: CGFloat { CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * gap }

    /// Snaps a drag to whole cells: a move shifts x/y, a resize changes w/h.
    func candidate(_ widget: PageWidget, translation: CGSize, resizing: Bool) -> PageWidget {
        let dx = Int((translation.width / (cellWidth + gap)).rounded())
        let dy = Int((translation.height / (rowHeight + gap)).rounded())
        var result = widget
        if resizing {
            let minimum = widget.kind.minimumSize
            result.w = max(minimum.w, widget.w + dx)
            result.h = max(minimum.h, widget.h + dy)
        } else {
            result.x = widget.x + dx
            result.y = widget.y + dy
        }
        return result
    }
}

/// A customized page: tiles at explicit grid positions, each bound to its own camera. In edit mode tiles
/// stop responding to touches; you drag them to move, drag the corner to resize, × to delete, and pick a
/// camera from the chip. A tile dropped on another swaps with it, and tiles in its way make room
/// (`PageLayout.moving`), shown while it's still held.
struct GridPageView: View {
    let store: DashboardStore
    let pageID: UUID
    let layout: PageLayout
    var isEditing: Bool = false
    /// Whether linking is on for this page and which controls are linked (for the chain badge).
    var linkState: (on: Bool, links: Set<LinkKind>) = (false, [])
    /// An automatic page of several cameras: rows held in a camera's column for another camera's controls show as
    /// empty tiles (`HeldGap`).
    var showsHeldGaps = false
    /// Which arrangement edits go to: the page's layout, or one camera's iPhone layout.
    var target: LayoutTarget = .page
    /// Where this grid's top-left is on the page, when it's one camera's part of it (a phone on its side): edits made
    /// here go back to the page there (`CameraArrangement`).
    var origin: GridSpot? = nil
    /// Rows never shorter than this, the page scrolling instead: one camera's 2-wide part of a page, edited on a phone on
    /// its side, would otherwise have rows a few points tall.
    var floorRow: CGFloat? = nil
    /// Reduce Motion: tiles move and make room without sliding, and an added tile is scrolled to without gliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drag: DragState?
    /// Where the other tiles go if the dragged one is dropped where it's resting, drawn there until it moves on.
    @State private var arranged: Arranged?
    /// The drop spot the finger is over, and the wait before the page shows it (`arrange`).
    @State private var pendingSpot: GridSpot?
    @State private var settle: Task<Void, Never>?
    /// The row height edit mode opened with, kept while tiles move so none shrinks or grows under the finger; a page
    /// that grows scrolls instead. Measured again when the space or Fit to Screen changes, dropped on Done.
    @State private var keptRows: KeptRows?
    /// A tile just added, outlined for a moment once it's scrolled into view.
    @State private var flash: UUID?
    /// How far the page has scrolled: its top above the view's, measured as it scrolls.
    @State private var scrolledBy: CGFloat = 0
    /// Where the page's view starts in the window, to tell where a finger is on it.
    @State private var viewportTop: CGFloat = 0
    /// The page scrolling under a tile held at its top or bottom edge (`scrollAtEdge`).
    @State private var edgeScroll: Task<Void, Never>?
    /// Tiles dropped somewhere new, for the tap a drop gives.
    @State private var drops = 0
    @Environment(\.liveViewOnScreen) private var onScreen
    @Environment(\.alignmentAudit) private var audit

    struct DragState {
        var widgetID: UUID
        var resizing: Bool
        var translation: CGSize
        /// How far the page had scrolled when the tile was picked up.
        var scrolledAtStart: CGFloat = 0
        /// Where the finger is, in the window (a move, not a resize).
        var finger: CGPoint? = nil

        /// The tile's move on the page: the finger's, plus however far the page has scrolled under it since.
        func moved(_ scrolledBy: CGFloat) -> CGSize {
            CGSize(width: translation.width, height: translation.height + scrolledBy - scrolledAtStart)
        }
    }

    struct Arranged {
        var widgetID: UUID
        var spot: GridSpot
        var layout: PageLayout
    }

    struct KeptRows: Equatable {
        var editing: Bool
        var size: CGSize
        var scrolls: Bool
        var rowHeight: CGFloat = 0
    }

    var body: some View {
        GeometryReader { geo in
            let pad = DashboardView.padding
            let inner = CGSize(width: max(geo.size.width - 2 * pad, 1), height: max(geo.size.height - 2 * pad, 1))
            // In use, tiles for controls their camera doesn't have (or an output it doesn't) drop out and each camera's
            // tiles close up; edit mode shows the saved arrangement as it is, missing controls grayed, so it can be fixed.
            let layout = isEditing ? self.layout
                : LayoutTemplates.closingGaps(in: self.layout) { store.camera($0.cameraID)?.offers($0) ?? true }
            let automatic = automaticRows(layout)
            let natural = GridMetrics(layout: layout, size: inner, keepRows: automatic, fitRows: scrolls ? automatic : nil,
                                      floorRow: floorRow)
            let key = KeptRows(editing: isEditing, size: inner, scrolls: scrolls)
            let kept = keptRows.flatMap { $0.editing && $0.size == inner && $0.scrolls == scrolls ? $0.rowHeight : nil }
            // Edit mode's spare rows, and room for tiles a held tile would push past them.
            let grown = max((arranged?.layout.rows ?? 0) - layout.rows, 0)
            let metrics = GridMetrics(layout: layout, size: inner, extraRows: isEditing ? 4 + grown : 0,
                                      keepRows: automatic, fitRows: scrolls ? automatic : nil,
                                      rowHeight: isEditing ? kept : nil, floorRow: floorRow)
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                grid(layout, metrics: metrics, scroller: Scroller(proxy: proxy, viewport: geo.size.height))
                    .frame(width: inner.width, height: metrics.contentHeight, alignment: .topLeading)
                    .padding(pad)
                    .id(Self.top)
                    .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(Self.space)).minY } action: { scrolledBy = $0 }
            }
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { viewportTop = $0 }
            // A held tile doesn't scroll the page, except at its edge, where the page scrolls itself (`scrollAtEdge`):
            // a disabled scroll view takes no programmatic scrolling either.
            .scrollDisabled(drag != nil && edgeScroll == nil)
            .scrollIndicators(.hidden)
            .modifier(EditHaptics(pickedUp: drag?.widgetID, madeRoom: arranged?.spot, drops: drops))
            .onChange(of: key, initial: true) { _, key in
                keptRows = key.editing ? KeptRows(editing: true, size: key.size, scrolls: key.scrolls, rowHeight: natural.rowHeight)
                    : nil
                if !key.editing { endDrag() }
            }
            .onChange(of: isEditing && pageID == store.currentPageID
                      ? GridCellShape(cellWidth: metrics.cellWidth, rowHeight: metrics.rowHeight, gap: metrics.gap) : nil,
                      initial: true) { _, cell in
                if let cell { store.editedGrid = (pageID, target, cell) }
            }
            .onChange(of: store.addedWidgetID) { _, id in
                guard let id, let widget = layout.widgets.first(where: { $0.id == id }) else { return }
                Task { @MainActor in
                    // After Add Tile's sheet has gone, so the scroll and the outline are seen.
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(RowAnchor(row: widget.y + widget.h / 2), anchor: .center)
                    }
                    flash = id
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeOut(duration: 0.4)) { if flash == id { flash = nil } }
                }
            }
            }
        }
    }

    /// The page's tiles on their grid, and, while one is held, where it would land.
    @ViewBuilder
    private func grid(_ layout: PageLayout, metrics: GridMetrics, scroller: Scroller) -> some View {
        ZStack(alignment: .topLeading) {
            // One anchor per half-row, to scroll a tile into view by its row.
            VStack(spacing: metrics.gap) {
                ForEach(0..<metrics.rows, id: \.self) { row in
                    Color.clear.frame(width: 1, height: metrics.rowHeight).id(RowAnchor(row: row))
                }
            }
            .allowsHitTesting(false)
            if isEditing { GridBackdrop(metrics: metrics) }
            if showsHeldGaps, !isEditing {
                ForEach(HeldGap.gaps(in: layout), id: \.self) { gap in
                    let rect = metrics.frame(x: gap.x, y: gap.y, w: gap.w, h: gap.h)
                    HeldGapTile(name: gap.name)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            ForEach(layout.widgets) { widget in
                if let camera = store.camera(widget.cameraID) {
                    // A tile making room for the one being dragged is drawn where it would go.
                    let shown = widget.id == drag?.widgetID ? widget
                        : arranged?.layout.widgets.first { $0.id == widget.id } ?? widget
                    tile(widget, at: shown, camera: camera, metrics: metrics,
                         scroller: scroller)
                        // Live view streams only from the page in front, and not while it's being arranged.
                        .environment(\.liveViewOnScreen, onScreen && pageID == store.currentPageID && !isEditing)
                }
            }
            // Where the drop would land: a move always lands (the others make room); a resize that would overlap
            // or leave the grid is red, and snaps back.
            if let drag, let widget = layout.widgets.first(where: { $0.id == drag.widgetID }) {
                let target = drag.resizing
                    ? metrics.candidate(widget, translation: drag.translation, resizing: true)
                    : placed(widget, at: dropSpot(widget, translation: drag.moved(scrolledBy), metrics: metrics))
                let rect = metrics.frame(target)
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill((!drag.resizing || layout.fits(target) ? Theme.timecode : Theme.recording).opacity(0.25))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private var scrolls: Bool { store.pages.first { $0.id == pageID }?.isScrolling ?? false }

    /// The rows these cameras' automatic layout has: the size a scrolling page's tiles keep.
    private func automaticRows(_ layout: PageLayout) -> Int {
        let cameras = layout.cameraIDs
        switch target {
        case .phone(let camera):
            return PageLayout(columns: LayoutTemplates.narrowColumns,
                              widgets: LayoutTemplates.block(camera: camera, profile: store.camera(camera)?.profile, wide: false)).rows
        case .page:
            let wide = layout.columns >= max(cameras.count, 1) * LayoutTemplates.wideColumns
            return LayoutTemplates.materialize(cameraIDs: cameras, wide: wide, profile: { store.camera($0)?.templateProfile }).rows
        }
    }

    /// Where a dragged tile would land if let go now (`PageLayout.dropSpot`): on the tile under its center, else where
    /// it's snapped to.
    private func dropSpot(_ widget: PageWidget, translation: CGSize, metrics: GridMetrics) -> GridSpot {
        let rect = metrics.frame(widget)
        let center = metrics.cell(at: CGPoint(x: rect.midX + translation.width, y: rect.midY + translation.height))
        let snapped = metrics.candidate(widget, translation: translation, resizing: false)
        return layout.dropSpot(for: widget.id, center: center, snapped: GridSpot(x: snapped.x, y: snapped.y))
    }

    /// A spot on this grid as a spot on the page: the same, unless this grid is one camera's part of it (`origin`).
    private func onPage(_ spot: GridSpot) -> GridSpot {
        guard let origin else { return spot }
        return GridSpot(x: spot.x + origin.x, y: spot.y + origin.y)
    }

    private func onPage(_ widget: PageWidget) -> PageWidget {
        guard let origin else { return widget }
        var moved = widget
        moved.x += origin.x
        moved.y += origin.y
        return moved
    }

    private func placed(_ widget: PageWidget, at spot: GridSpot) -> PageWidget {
        var moved = widget
        moved.x = spot.x
        moved.y = spot.y
        return moved
    }

    /// The other tiles make room for a drop at `spot` once the finger has rested on it for a moment, as on the Home
    /// Screen, so a tile carried across the page doesn't shuffle everything it passes over.
    private func arrange(_ widget: PageWidget, at spot: GridSpot) {
        guard spot != pendingSpot else { return }
        pendingSpot = spot
        settle?.cancel()
        let preview = layout.moving(widget.id, to: spot)
        settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                arranged = preview.map { Arranged(widgetID: widget.id, spot: spot, layout: $0) }
            }
        }
    }

    private func endDrag() {
        settle?.cancel()
        settle = nil
        edgeScroll?.cancel()
        edgeScroll = nil
        drag = nil
        arranged = nil
        pendingSpot = nil
    }

    /// The page's scroll view, for carrying a tile past its edge.
    struct Scroller {
        let proxy: ScrollViewProxy
        /// The view's height: the part of the page on screen.
        let viewport: CGFloat
    }

    nonisolated static let space = "grid-page"

    /// A half-row's place on the page, to scroll to: its own type, so it can't be taken for another view's id (the edit
    /// grid's cells are numbered too, and scrolling to "row 1" once went to the second cell of the top row).
    struct RowAnchor: Hashable {
        let row: Int
    }
    static let top = "grid-page-top"

    /// A tile held at the top or bottom edge scrolls the page under it, a row at a time while it's there, so a tile can
    /// go anywhere on a page taller than the screen. The finger moving off the edge, or the drop, stops it.
    private func scrollAtEdge(_ widget: PageWidget, metrics: GridMetrics, scroller: Scroller) {
        guard edgeScroll == nil else { return }
        let pad = DashboardView.padding, step = metrics.rowHeight + metrics.gap
        // The finger, not the tile, finds the edge: a tall tile held near its own bottom would otherwise never get there.
        let edge = max(64, scroller.viewport * 0.1)
        let bottom = max(metrics.contentHeight + 2 * pad - scroller.viewport, 0)
        func direction() -> CGFloat {
            guard let drag, drag.widgetID == widget.id, !drag.resizing, let finger = drag.finger else { return 0 }
            let y = finger.y - viewportTop
            if y > scroller.viewport - edge, scrolledBy < bottom - 1 { return 1 }
            if y < edge, scrolledBy > 1 { return -1 }
            return 0
        }
        guard direction() != 0 else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled, case let way = direction(), way != 0 {
                // To the next half-row's anchor in that direction, from wherever the page is: always at least one row,
                // however short the rows (rounding to the nearest once kept an iPhone's page where it was).
                let at = (scrolledBy - pad) / step
                withAnimation(.linear(duration: 0.12)) {
                    if way > 0 {
                        let row = min(Int((at + 0.01).rounded(.down)) + 1, metrics.rows - 1)
                        scroller.proxy.scrollTo(RowAnchor(row: row), anchor: .top)
                    } else if case let row = Int((at - 0.01).rounded(.up)) - 1, row >= 0 {
                        scroller.proxy.scrollTo(RowAnchor(row: row), anchor: .top)
                    } else {
                        scroller.proxy.scrollTo(Self.top, anchor: .top)
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
                if let drag { arrange(widget, at: dropSpot(widget, translation: drag.moved(scrolledBy), metrics: metrics)) }
            }
            edgeScroll = nil
        }
    }

    /// One tile, drawn at `shown`: where it is, or where it would go to make room for a tile being dragged.
    @ViewBuilder
    private func tile(_ widget: PageWidget, at shown: PageWidget, camera real: CameraController,
                      metrics: GridMetrics, scroller: Scroller) -> some View {
        let rect = metrics.frame(shown)
        let moving = drag?.widgetID == widget.id && drag?.resizing == false
        let linkKind = LinkKind.forWidget(widget.kind)
        let linked = linkState.on && linkKind.map { linkState.links.contains($0) } == true
        let hasValueTile = layout.widgets.contains { $0.kind == .shutterValue && $0.cameraID == widget.cameraID }
        // The LUT on/off tile on every output is the LUT tile's Outputs switch: one of them on the page, not both.
        let hasLUTSwitchTile = layout.widgets.contains {
            ($0.kind == .viewAssist || $0.kind == .look) && $0.cameraID == widget.cameraID && $0.targets.isEmpty
        }
        // Editing, a camera that isn't connected is drawn as a demo of itself, so the page can be laid out with it off;
        // tiles take no taps here, and the edits go to the real camera's tiles. In Test Mode it's a working demo on every
        // page, so the page can be tried out too.
        let camera = store.shownController(for: real, editing: isEditing)
        // The HaLow tile shows the node this device is on, else the first one.
        WidgetView(kind: widget.kind, camera: camera, isLinked: linked, dialSwitch: !hasValueTile,
                   haLowStats: store.haLowNodes.first?.stats,
                   haLowNodeState: store.haLowNodes.first?.state,
                   store: store, output: widget.output, outputs: widget.targets, showsStep: widget.stepButtons,
                   lutSwitch: !hasLUTSwitchTile)
            .allowsHitTesting(!isEditing)
            .frame(width: rect.width, height: rect.height)
            .environment(\.alignmentAudit, audit.map { "\($0)(\(widget.x),\(widget.y)) " })
            .overlay {
                if flash == widget.id {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(Theme.locked, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isEditing {
                    EditOverlay(
                        widget: widget,
                        camera: camera,
                        cameras: target == .page ? store.cameras : [camera],  // a phone layout is one camera's
                        size: rect.size,
                        onDrag: { translation, resizing, finger in
                            let start = drag?.widgetID == widget.id ? drag?.scrolledAtStart ?? scrolledBy : scrolledBy
                            let held = DragState(widgetID: widget.id, resizing: resizing, translation: translation,
                                                 scrolledAtStart: start, finger: finger)
                            drag = held
                            guard !resizing else { return }
                            arrange(widget, at: dropSpot(widget, translation: held.moved(scrolledBy), metrics: metrics))
                            scrollAtEdge(widget, metrics: metrics, scroller: scroller)
                        },
                        onDrop: { translation, resizing in
                            let moved = drag?.moved(scrolledBy) ?? translation
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                                if resizing {
                                    // A resize that would overlap or leave the grid changes nothing: the corner snaps back.
                                    store.placeWidget(pageID, onPage(metrics.candidate(widget, translation: translation, resizing: true)),
                                                      in: target)
                                } else if store.moveWidget(pageID, widget.id,
                                                           to: onPage(dropSpot(widget, translation: moved, metrics: metrics)),
                                                           in: target) {
                                    drops += 1
                                }
                                endDrag()
                            }
                        },
                        onDelete: { store.removeWidget(pageID, widget.id, in: target) },
                        onCamera: { store.setWidgetCamera(pageID, widget.id, cameraID: $0) },
                        // A monitoring switch on a camera with outputs: which one it switches, or all of them.
                        outputs: camera.state.monitoring?.outputs(for: widget.kind) ?? [],
                        everyOutput: widget.kind.takesEveryOutput,
                        onOutput: { store.setWidgetOutput(pageID, widget.id, output: $0, in: target) },
                        onOutputs: { store.setWidgetOutputs(pageID, widget.id, outputs: $0, in: target) },
                        onStep: { store.setWidgetStep(pageID, widget.id, on: $0, in: target) },
                        onMoveAll: { store.moveTiles(pageID, from: widget.cameraID, to: $0) }
                    )
                }
            }
            .offset(x: rect.minX + (moving ? drag?.moved(scrolledBy).width ?? 0 : 0),
                    y: rect.minY + (moving ? drag?.moved(scrolledBy).height ?? 0 : 0))
            .zIndex(moving ? 1 : 0)
    }
}

/// Faint cell outlines behind the tiles in edit mode, including spare rows below to drop into.
/// Rows an automatic page of several cameras holds in a camera's column because another camera has controls there
/// (cameras line up row by row, `LayoutTemplates.materialize`). Left as holes they read as a page drawn wrong: an FX3
/// beside an FX6 has a blank where the FX6's ND is. Each shows as an empty tile, named when the
/// other cameras have one control there ("No ND"); where they have several (a VENICE's LUT and False Color switches,
/// beside an FX6 whose LUT tile has the same switch), nothing is claimed.
struct HeldGap: Hashable {
    var x: Int, y: Int, w: Int, h: Int
    var name: String?

    static func gaps(in layout: PageLayout) -> [HeldGap] {
        let byCamera = Dictionary(grouping: layout.widgets, by: \.cameraID)
        guard byCamera.count > 1 else { return [] }
        var gaps: [HeldGap] = []
        for (camera, widgets) in byCamera {
            guard let left = widgets.map(\.x).min(), let right = widgets.map(\.maxX).max() else { continue }
            let others = layout.widgets.filter { $0.cameraID != camera }
            func covered(_ row: Int, by tiles: [PageWidget]) -> Bool { tiles.contains { $0.y <= row && row < $0.maxY } }
            var run: [Int] = []
            func close() {
                guard let top = run.first, let bottom = run.last else { return }
                let there = others.filter { $0.y <= bottom && top < $0.maxY }
                let names = Set(there.map { family($0.kind) })
                let own = Set(widgets.map { family($0.kind) })
                let name = names.count == 1 && own.isDisjoint(with: names) ? names.first.map { "No \($0)" } : nil
                gaps.append(HeldGap(x: left, y: top, w: right - left, h: bottom - top + 1, name: name))
                run = []
            }
            for row in 0..<layout.rows {
                if !covered(row, by: widgets) && covered(row, by: others) { run.append(row) } else { close() }
            }
            close()
        }
        return gaps.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    /// One control's tiles under one name: ND's picker, its steps and its mode are all ND.
    static func family(_ kind: WidgetKind) -> String {
        switch kind {
        case .ndPreset, .ndMinus, .ndPlus, .ndMode: "ND"
        default: kind.title
        }
    }
}

/// A held row's tile: the tile's shape, quieter than a tile, and what the camera hasn't got, where that's one thing.
/// Light tiles (Settings → Appearance's outdoor colors) take less of it: at half, white tiles left a gray slab.
struct HeldGapTile: View {
    var name: String?
    @Environment(\.tileScale) private var s

    var body: some View {
        let lightTiles = ThemeStore.shared.appearance.palette?.tile.isLight == true
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .fill(Theme.tile.opacity(lightTiles ? 0.14 : 0.5))
            .overlay {
                if let name {
                    Caption(name, color: Theme.secondaryText)
                        .opacity(0.7)
                        .padding(.horizontal, Theme.inset * s)
                }
            }
            .accessibilityHidden(true)
    }
}

struct GridBackdrop: View {
    let metrics: GridMetrics

    var body: some View {
        ForEach(0..<metrics.rows, id: \.self) { row in
            ForEach(0..<metrics.columns, id: \.self) { column in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.backgroundText.opacity(0.07), lineWidth: 1)
                    .frame(width: metrics.cellWidth, height: metrics.rowHeight)
                    .offset(x: CGFloat(column) * (metrics.cellWidth + metrics.gap),
                            y: CGFloat(row) * (metrics.rowHeight + metrics.gap))
            }
        }
        .allowsHitTesting(false)
    }
}

extension WidgetKind {
    /// The tile's name for this camera, where it isn't the same for every camera: the LUT a Blackmagic camera puts on
    /// its outputs is "LUT", where Sony calls the switch View Assist; ARRI calls focus assist Peaking, and its LUT a
    /// look.
    public func title(for state: CameraState) -> String {
        switch self {
        case .viewAssist where state.make == .arri: "Look"
        case .viewAssist where state.lutIsOnOutputs: "LUT"
        case .focusAssist where state.make == .arri: "Peaking"
        case .lut where state.make == .arri: "Look"
        default: title
        }
    }
}

extension CameraState {
    /// The LUT switch (`look`) puts the LUT on monitoring outputs (Blackmagic), not Sony's View Assist.
    var lutIsOnOutputs: Bool { monitoring != nil }
}

struct EditOverlay: View {
    let widget: PageWidget
    let camera: CameraController
    let cameras: [CameraController]
    /// The tile's size: a half-row tile gets a smaller camera chip.
    var size: CGSize
    /// The drag so far, whether it's a resize, and where the finger is in the window (a move only).
    var onDrag: (CGSize, Bool, CGPoint?) -> Void
    var onDrop: (CGSize, Bool) -> Void
    var onDelete: () -> Void
    var onCamera: (UUID) -> Void
    /// The outputs a monitoring switch can be set to: its camera's, where it sets overlays output by output. Empty for
    /// every other tile.
    var outputs: [MonitorOutput] = []
    /// All Outputs is one of the choices (not for what status text shows, which differs by output).
    var everyOutput = true
    var onOutput: (TileOutput?) -> Void = { _ in }
    /// Several outputs at once (a switch that can be on every output can be on any few of them too).
    var onOutputs: ([TileOutput]) -> Void = { _ in }
    /// The ND tile's step buttons on or off (`PageWidget.showsStep`).
    var onStep: (Bool) -> Void = { _ in }
    /// Gives every tile of this tile's camera on the page to another camera.
    var onMoveAll: (UUID) -> Void = { _ in }

    /// The outputs checklist is open (a switch that can be on several outputs).
    @State private var choosingOutputs = false

    /// How much of the screen a corner control answers to: a thumb on an iPad on set, not a pointer.
    private static let target: CGFloat = 36
    /// How far a corner control reaches past its tile: half the gap, so a neighbor's never overlaps it.
    private static let reach = Theme.gap / 2

    /// A chip's height: a half-row tile gets smaller ones.
    private var chipHeight: CGFloat { size.height < 34 ? 20 : 28 }

    /// A half-row tile on an iPhone on its side is about 20 pt tall: full-size corner controls overhang the tile below.
    /// Its controls are smaller, and stay inside it.
    private var isShort: Bool { size.height < 34 }
    private var controlTarget: CGFloat { isShort ? 24 : Self.target }
    private var controlSize: CGFloat { isShort ? 17 : 24 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Color.black.opacity(0.35))
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Theme.strong.opacity(0.75))
            // Under the tile's name, a monitoring switch's output: set here, so in use a tap only turns it on and off.
            // Beside the name in a short tile, or alone in a small one (the tile shows its name under the overlay), and
            // never under a corner control: an iPhone's tiles are too short to clear them above and below.
            if widget.kind.takesStep {
                // The ND tile's option, under its name: its − + step buttons, on or off.
                ViewThatFits {
                    VStack(spacing: 6) { nameChip; stepChip }
                    HStack(spacing: 6) { nameChip; stepChip }
                    stepChip
                }
                .padding(.horizontal, controlTarget - Self.reach)
            } else if outputs.isEmpty && widget.targets.isEmpty {
                // Between the corner controls where the tile is too short for the name to clear them above and below:
                // on a half-row tile the name runs under its × and into its resize handle. Too
                // narrow there for the name, the camera's letter alone (the tile shows its own name under the
                // overlay); on a page of one camera, nothing.
                ViewThatFits {
                    nameChip
                    if cameras.count > 1 { cameraChip }
                    Color.clear.frame(width: 0, height: 0)
                }
                .padding(.horizontal, size.height < 2 * (controlTarget - Self.reach) + 28 ? controlTarget - Self.reach : 0)
            } else {
                ViewThatFits {
                    VStack(spacing: 6) { nameChip; outputChip }
                    HStack(spacing: 6) { nameChip; outputChip }
                    HStack(spacing: 6) { if cameras.count > 1 { cameraChip }; outputChip }
                }
                .padding(.horizontal, controlTarget - Self.reach)
            }
        }
        .contentShape(Rectangle())
        // The outputs checklist hangs off the tile, not the chip: the chip moves between layouts as its name grows
        // ("SDI 1/2" → "SDI 1/2 + SDI 3/4"), and a popover anchored to it closed when it moved.
        .popover(isPresented: $choosingOutputs, attachmentAnchor: .rect(.bounds)) {
            outputsChecklist
                .presentationCompactAdaptation(.popover)
        }
        // Measured in the window, not in this view: the tile moves with the drag, and measured in its own moving
        // coordinates every other reading came out near zero, so the tile shivered between the finger and home.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onDrag($0.translation, false, $0.location) }
                .onEnded { onDrop($0.translation, false) }
        )
        // Delete top-left and resize bottom-right, each reaching half the gap past its corner, so they never meet,
        // a neighbor's never overlaps them, and each has a full-size target even on a half-row tile.
        .overlay(alignment: .topLeading) {
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.symbol(controlSize, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Theme.recording)
                    .frame(width: controlTarget, height: controlTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: -Self.reach, y: -Self.reach)
            .accessibilityLabel("Remove \(widget.kind.title(for: camera.state))")
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(Theme.symbol(isShort ? 8 : 11, weight: .bold))
                .foregroundStyle(Color.black)
                .frame(width: controlSize, height: controlSize)
                .background(Color.white.opacity(0.9), in: Circle())
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(Rectangle())
                .offset(x: Self.reach, y: Self.reach)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { onDrag($0.translation, true, nil) }
                        .onEnded { onDrop($0.translation, true) }
                )
        }
    }

    /// The camera's letter beside the tile's name, so which camera a tile follows reads at a glance; tap it to choose
    /// another.
    private var nameChip: some View {
        HStack(spacing: 6) {
            if cameras.count > 1 { cameraChip }
            Text(widget.kind.title(for: camera.state))
                .font(Theme.caption)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.leading, cameras.count > 1 ? 2 : 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.6), in: Capsule())
    }

    /// Which outputs the tile switches, with ⌄. A switch that can be on every output takes any few of them (the LUT on
    /// SDI 1/2 and SDI 3/4, not the monitor): the chip opens a checklist — All Outputs, then each output, ticked where
    /// it's on — that stays open while outputs are ticked (macOS menus can't be told to stay open). Ticking every output
    /// is All Outputs. What status text shows is one
    /// output's, picked from a menu as before. One the camera hasn't reported (it's offline) stays in the list, so the
    /// tile still says what it's set to.
    @ViewBuilder
    private var outputChip: some View {
        let chosen = widget.targets
        let name = chosen.isEmpty ? (everyOutput ? "All Outputs" : "Choose Output") : WidgetView.outputsName(chosen)
        if everyOutput {
            Button { choosingOutputs = true } label: { chipLabel(name) }
                .buttonStyle(.plain)
                .accessibilityLabel("Outputs: \(name). Change")
        } else {
            let choices = outputChoices
            Menu {
                Picker("Output", selection: Binding(get: { widget.output?.id },
                                                    set: { id in onOutput(choices.first { $0.id == id }) })) {
                    ForEach(choices, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel(name)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Output: \(name). Change")
        }
    }

    /// The ND tile's step buttons, Step On or Step Off: a tap switches them.
    private var stepChip: some View {
        let on = widget.stepButtons
        return Button { onStep(!on) } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(Theme.symbol(11))
                Text("Step \u{2212} +")
                    .font(Theme.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .frame(minHeight: chipHeight)
            .background(Color.black.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step buttons")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityIdentifier("stepChip")
    }

    /// The camera's outputs, and any the tile is set to that the camera hasn't reported (it's offline).
    private var outputChoices: [TileOutput] {
        let saved = widget.targets.filter { target in !outputs.contains { $0.id == target.id } }
        return outputs.map(TileOutput.init) + saved
    }

    private func chipLabel(_ name: String) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(Theme.caption)
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Chevron()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: chipHeight)
        .background(Color.black.opacity(0.6), in: Capsule())
        .contentShape(Capsule())
        .fixedSize()
    }

    /// All Outputs, then each output with a tick where the tile is on it. A tap changes the tile at once and the list
    /// stays: tap outside it when done.
    private var outputsChecklist: some View {
        let chosen = widget.targets
        let choices = outputChoices
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(widget.kind.title(for: camera.state)) Outputs")
                .font(Theme.caption)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.sheet.secondaryText)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            checklistRow("All Outputs", ticked: chosen.isEmpty) { onOutputs([]) }
            Divider().padding(.horizontal, 14)
            ForEach(choices, id: \.id) { choice in
                let on = chosen.contains { $0.id == choice.id }
                checklistRow(choice.name, ticked: on) {
                    var next = chosen.filter { $0.id != choice.id }
                    if !on { next = choices.filter { c in next.contains { $0.id == c.id } || c.id == choice.id } }
                    // Every output chosen is All Outputs; none left is All Outputs too.
                    onOutputs(next.count == choices.count ? [] : next)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 200, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    private func checklistRow(_ title: String, ticked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.sheet.text)
                    .opacity(ticked ? 1 : 0)
                    .frame(width: 18)
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.sheet.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }

    /// This tile's camera, or every one of that camera's tiles on the page: a page laid out on a demo camera goes to the
    /// real one in one step.
    private var cameraChip: some View {
        let height = chipHeight
        return Menu {
            Section("This Tile") {
                ForEach(cameras) { option in
                    Toggle("Camera \(option.slot.label)", isOn: Binding(get: { option.id == camera.id },
                                                                       set: { if $0 { onCamera(option.id) } }))
                }
            }
            Section("All of Camera \(camera.slot.label)'s Tiles") {
                ForEach(cameras.filter { $0.id != camera.id }) { option in
                    Button("Move to Camera \(option.slot.label)") { onMoveAll(option.id) }
                }
            }
        } label: {
            Text(camera.slot.label)
                .font(Theme.letter(height < 28 ? 11 : 14))
                .foregroundStyle(camera.slot.badgeText)
                .frame(minWidth: height, minHeight: height)
                .padding(.horizontal, 2)
                .background(camera.slot.tint, in: Capsule())
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Camera \(camera.slot.label): change")
    }
}

/// A tile picked up, the page making room for it, and a drop each give a tap (iPhone, iPad).
struct EditHaptics: ViewModifier {
    let pickedUp: UUID?
    let madeRoom: GridSpot?
    let drops: Int

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: pickedUp, Self.pickUp)
            .sensoryFeedback(trigger: madeRoom, Self.room)
            .sensoryFeedback(.impact(weight: .medium), trigger: drops)
    }

    static func pickUp(_ old: UUID?, _ new: UUID?) -> SensoryFeedback? {
        old == nil && new != nil ? .impact(weight: .light) : nil
    }

    static func room(_ old: GridSpot?, _ new: GridSpot?) -> SensoryFeedback? {
        new != nil && new != old ? .selection : nil
    }
}


