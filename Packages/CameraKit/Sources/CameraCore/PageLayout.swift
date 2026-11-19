import CryptoKit
import Foundation

/// Every kind of tile a page can hold.
public enum WidgetKind: String, Codable, CaseIterable, Sendable {
    case timecode, label, ndPreset, ndMinus, ndPlus, shutterDial, shutterValue, frameRate, iso
    case wbPreset, wbSliders, iris, record, status, battery, media, clipName, latency, format
    case colorBars, falseColor, look, sensorFlip, webGUI
    /// One tap: the camera's info on its HDMI output (off: clean HDMI), and its grid lines. Sony.
    case hdmiInfo, gridLines
    /// Tappable resolution picker (from camera-offered options).
    case resolution
    /// Tappable codec/file-format/bitrate picker.
    case codec
    /// Anamorphic de-squeeze selector.
    case desqueeze
    /// View Assist / Gamma Display Assist toggle (replaces the old `.look` in new layouts;
    /// `.look` remains valid so saved layouts don't break).
    case viewAssist
    /// LUT picker + View Assist toggle side by side.
    case lut
    /// AF / MF two-state switch.
    case focusMode
    /// Bitrate and sampling (Sony's Recording Setting), separate from the codec.
    case bitrate
    /// HaLow mesh node link stats (signal, rate, retries). Opt-in only; never in default templates.
    case haLow
    /// The camera's picture in the tile, pulled only while the tile is on screen. Tap for the live view window.
    /// Opt-in only; never in the default templates.
    case liveView
    /// A button that opens the live view window. Sends nothing until tapped. Opt-in only.
    case liveViewButton
    /// Playback controls tile (play/pause, skip, next/prev, FF/REW, stop/live).
    /// Beside the frame rate on iPad and Mac; over REC on iPhone (REC stays last). Dropped if the camera has no playback.
    case playback
    /// The recorded gamma (Blackmagic's dynamic range) picker.
    case dynamicRange
    /// What each monitoring output shows; a tap opens them output by output.
    case monitoring
    /// Zebra, focus assist and frame guides on every output, one tap each.
    case zebra, focusAssist, frameGuides
    /// Clean feed, one tap: on one output (SDI to start with) or on every output, picked in edit mode.
    case cleanFeed
    /// Status text on and off, one tap, the same way (a Blackmagic camera's, through a preset).
    case statusText
    /// What one output's status text shows: SDI's for the cinematographer or the director, the LCD's and USB-C's meters
    /// or codec and resolution. Its output is picked in edit mode (SDI to start with).
    case statusTextContent
    /// The top bar's padlock as a tile: locks and unlocks every tile. The app's, not the camera's, so
    /// every camera offers it. Add Tile only; no default layout has it.
    case lock
    /// The ND's STEP/VARIABLE switch, the camera's tally lamps, CALL on its display, and the color gamut it records:
    /// what the BURANO lets the network set (docs/burano-controls.md). Add Tile only.
    case ndMode, tally, call, colorGamut
    /// A button that opens the camera's own buttons (MENU, Home, Back, the multi-selector), to work its menu on an
    /// external monitor without its own screen. Add Tile only.
    case cameraMenu
    /// One-shot autofocus (a Blackmagic camera with a lens it can focus). Add Tile only.
    case autoFocus
    /// The camera's audio: a Blackmagic camera's channels (input and gain, a tap for the rest), a VENICE's meters. Add
    /// Tile only.
    case audio
    /// What a VENICE's frame line sets A and B show of its user frame lines: a tap steps on as the camera's own User
    /// Frame Disp. button does, a long press picks one. Add Tile only.
    case userFrameA, userFrameB
    /// An FX6's: its shooting mode, the LUT baked into the recording, proxy recording, ECS, the focus and zoom driven
    /// from the tile, and its assignable buttons (docs/fx6-controls.md). Add Tile only.
    case shootingMode, recordedLUT, proxy, ecs, focusDrive, zoomDrive, assignable
    /// A Sony body's SteadyShot and an FX5's Imager Mode (docs/fx5-controls.md). Add Tile only.
    case steadyShot, imagerMode
    /// A Sony body's autofocus settings, in a window (`AFSettingsView`). Add Tile only.
    case afSettings
    /// The camera's clips, in a window that plays the one picked (`ClipListView`). Add Tile only.
    case clips

    public var title: String {
        switch self {
        case .timecode: "Timecode / REC Time"
        case .label: "Camera Letter"
        case .ndPreset: "ND"
        case .ndMinus: "ND −"
        case .ndPlus: "ND +"
        case .shutterDial: "Shutter Dial"
        case .shutterValue: "Shutter"
        case .frameRate: "Frame Rate"
        case .iso: "ISO / EI"
        case .wbPreset: "White Balance"
        case .wbSliders: "Temp / Tint"
        case .iris: "Iris"
        case .record: "REC"
        case .status: "Battery / Media"
        case .battery: "Battery"
        case .media: "Media"
        case .clipName: "Naming"
        case .latency: "Latency"
        case .format: "Format"
        case .colorBars: "Color Bars"
        case .falseColor: "False Color"
        case .look: "View Assist"
        case .sensorFlip: "Sensor Flip"
        case .hdmiInfo: "HDMI Info"
        case .gridLines: "Grid Lines"
        case .webGUI: "Web GUI"
        case .resolution: "Resolution"
        case .codec: "Codec"
        case .desqueeze: "De-squeeze"
        case .viewAssist: "View Assist"
        case .lut: "LUT"
        case .focusMode: "AF / MF"
        case .bitrate: "Bitrate"
        case .haLow: "HaLow"
        case .liveView: "Live View"
        case .liveViewButton: "Live View Button"
        case .playback: "Playback"
        case .dynamicRange: "Dynamic Range"
        case .monitoring: "Monitoring Options"
        case .zebra: "Zebra"
        case .focusAssist: "Focus Assist"
        case .frameGuides: "Frame Guides"
        case .cleanFeed: "Clean Feed"
        case .statusText: "Status Text"
        case .statusTextContent: "Status Text For"
        case .lock: "Lock"
        case .ndMode: "ND Mode"
        case .tally: "Tally"
        case .call: "Call"
        case .colorGamut: "Color Gamut"
        case .cameraMenu: "Camera Menu"
        case .autoFocus: "Autofocus"
        case .audio: "Audio"
        case .userFrameA: "User Frame A"
        case .userFrameB: "User Frame B"
        case .shootingMode: "Shooting Mode"
        case .recordedLUT: "Recorded LUT"
        case .proxy: "Proxy"
        case .ecs: "ECS"
        case .focusDrive: "Focus"
        case .zoomDrive: "Zoom"
        case .assignable: "Assignable"
        case .steadyShot: "SteadyShot"
        case .imagerMode: "Imager Mode"
        case .afSettings: "AF Settings"
        case .clips: "Clips"
        }
    }

    /// The monitoring overlay a one-tap tile switches: on a camera that sets overlays output by output (Blackmagic), the
    /// tile can be set to one output (`PageWidget.output`). Nil for every other tile.
    public var monitorOverlay: MonitorOverlay? {
        switch self {
        case .look, .viewAssist: .lut
        case .falseColor: .falseColor
        case .zebra: .zebra
        case .focusAssist: .focusAssist
        case .frameGuides: .frameGuides
        case .cleanFeed: .cleanFeed
        case .statusText: .statusText
        default: nil
        }
    }

    /// The tile is set to one of its camera's outputs in edit mode (`PageWidget.output`): the monitoring switches, and
    /// what an output's status text shows.
    public var takesOutput: Bool { monitorOverlay != nil || self == .statusTextContent }

    /// It can be set to every output at once as well as to one: not what status text shows, which differs by output.
    public var takesEveryOutput: Bool { monitorOverlay != nil }

    /// Smallest size a tile can be resized to before its contents stop fitting: columns × half-rows.
    public var minimumSize: (w: Int, h: Int) { spec.minimumSize }

    /// Size when added from the palette: columns × half-rows.
    public var defaultSize: (w: Int, h: Int) { spec.defaultSize }

    /// One source of truth for every layout threshold for this tile kind.
    /// Call sites in `TileFrame`, `FrameRateTile`, etc. read from here so a global change is one edit.
    public var spec: TileSpec {
        switch self {
        // Identity — no caption, always 1×1 min
        // timecode: HH:MM:SS fits in 1×1 (one half-row)
        case .timecode:     TileSpec(min: (1,1), def: (1,1))
        // label: letter + model needs at least 2 half-rows to read at rest
        case .label:        TileSpec(min: (1,2), def: (1,2))
        // status: battery + card, two items; needs 1 col × 2 half-rows minimum
        case .status:       TileSpec(min: (1,2), def: (1,2))
        // battery, media: single captioned reading; 1×1 like latency
        case .battery:      TileSpec(min: (1,1), def: (1,1))
        case .media:        TileSpec(min: (1,1), def: (1,1))
        // latency: icon + "999 ms" fits in 1×1; the caption joins them on one line from 160 pt wide
        case .latency:      TileSpec(min: (1,1), def: (1,1), captionFrom: 160)
        // Exposure — value pickers
        // ndPreset: caption + value + ±buttons, needs 1×2 minimum
        case .ndPreset:     TileSpec(min: (1,2), def: (2,2), trailingFrom: 240)
        case .ndMinus:      TileSpec(min: (1,1), def: (1,2))
        case .ndPlus:       TileSpec(min: (1,1), def: (1,2))
        // shutterDial: falls back to value face below 90pt; 1×2 keeps it readable as value tile
        case .shutterDial:  TileSpec(min: (1,2), def: (1,4))
        // shutterValue: caption + value; 1×1 one-line is legible minimum
        case .shutterValue: TileSpec(min: (1,1), def: (1,1), trailingFrom: 260, footerFrom: 110)
        // frameRate: caption + value + Fixed|Variable switch; 1×2 keeps switch accessible
        case .frameRate:    TileSpec(min: (1,2), def: (1,4), trailingFrom: 260, footerFrom: 110)
        // iso: caption + value + Base switch; 2 half-rows minimum to show value + header switch
        case .iso:          TileSpec(min: (1,2), def: (2,4), trailingFrom: 300, footerFrom: 110)
        // wbPreset: caption + value, 1×1 is fine
        case .wbPreset:     TileSpec(min: (1,1), def: (1,2))
        // wbSliders: two slider rows with captions need at least 3 half-rows
        case .wbSliders:    TileSpec(min: (1,3), def: (1,4))
        // iris: slider + caption; 56pt one-line threshold; 2 half-rows minimum
        case .iris:         TileSpec(min: (1,2), def: (2,2), oneLineBelow: 56)
        // record: REC circle; needs at least 2 half-rows to see the circle
        case .record:       TileSpec(min: (1,2), def: (1,2))
        // Naming / clip
        // clipName: one column fits the letter and reel inline (a Blackmagic camera's whole name); wider shows more parts
        case .clipName:     TileSpec(min: (1,1), def: (1,1))
        case .format:       TileSpec(min: (1,1), def: (2,2))
        // Codec / format
        // resolution: text value, can be long ("3840×2160"); 1×1 one-line is minimum
        case .resolution:   TileSpec(min: (1,1), def: (2,2))
        // codec: text value; 1×1
        case .codec:        TileSpec(min: (1,1), def: (2,2))
        // bitrate: "600M" + "4:2:2 10bit" detail; 1×1 works
        case .bitrate:      TileSpec(min: (1,1), def: (1,2))
        case .desqueeze:    TileSpec(min: (1,1), def: (2,2))
        case .dynamicRange: TileSpec(min: (1,1), def: (2,2))
        // Monitoring / lens
        // toggle tiles: just a centered label; 1×1 minimum (reads as one line)
        case .colorBars:    TileSpec(min: (1,1), def: (1,2))
        case .falseColor:   TileSpec(min: (1,1), def: (1,2))
        case .look:         TileSpec(min: (1,1), def: (1,2))
        case .sensorFlip:   TileSpec(min: (1,1), def: (1,2))
        case .hdmiInfo, .gridLines: TileSpec(min: (1,1), def: (1,2))
        case .viewAssist:   TileSpec(min: (1,1), def: (2,2))
        // lut: caption + name + FC/ON switches; needs 2 cols × 2 half-rows for switches to be tappable
        case .lut:          TileSpec(min: (2,2), def: (2,2), trailingFrom: 250, oneLineBelow: 58)
        // focusMode: caption + segmented control; 1 col × 2 half-rows minimum to hit the switch
        case .focusMode:    TileSpec(min: (1,2), def: (1,2), oneLineBelow: 60)
        // zebra/focusAssist/frameGuides/cleanFeed: single toggle label (and its output); 1×1 minimum
        case .zebra:        TileSpec(min: (1,1), def: (1,2))
        case .focusAssist:  TileSpec(min: (1,1), def: (1,2))
        case .frameGuides:  TileSpec(min: (1,1), def: (1,2))
        case .cleanFeed:    TileSpec(min: (1,1), def: (1,2))
        case .statusText:   TileSpec(min: (1,1), def: (1,2))
        // statusTextContent: caption + a two-way switch, as focus: 2 half-rows; two columns, or one line squeezes the
        // switch past reading ("Cine" where "Cinematographer" doesn't fit)
        case .statusTextContent: TileSpec(min: (2,2), def: (2,2), oneLineBelow: 60)
        // monitoring: "Monitoring Options ›", which wraps to two lines in a narrow column
        case .monitoring:   TileSpec(min: (1,1), def: (2,2))
        case .webGUI:       TileSpec(min: (1,1), def: (1,2))
        // Live view / media
        // liveView: picture + icon fallback; 2×2 minimum for a useful preview
        case .liveView:     TileSpec(min: (2,2), def: (2,2))
        // liveViewButton: just the icon + "LIVE VIEW" label; 1×1 minimum
        case .liveViewButton: TileSpec(min: (1,1), def: (1,2))
        // playback: transport buttons row; needs 2 cols and 2 half-rows
        case .playback:     TileSpec(min: (2,2), def: (2,2))
        // haLow: caption + signal on one line; details drop as it narrows (HaLowTile)
        case .haLow:        TileSpec(min: (1,1), def: (2,2))
        // lock: the padlock and "Lock" on one line, as a toggle's title; 1×1 minimum
        case .lock:         TileSpec(min: (1,1), def: (1,2))
        // ndMode/tally/colorGamut: caption + a short value picker; call: a toggle; cameraMenu: an icon and a label
        case .ndMode, .tally: TileSpec(min: (1,1), def: (1,2))
        case .call:         TileSpec(min: (1,1), def: (1,2))
        case .colorGamut:   TileSpec(min: (1,1), def: (2,2))
        case .cameraMenu:   TileSpec(min: (1,1), def: (1,2))
        // autoFocus: a one-shot button, its label alone; userFrameA/B: caption + a short value picker
        case .autoFocus:    TileSpec(min: (1,1), def: (1,2))
        case .userFrameA, .userFrameB: TileSpec(min: (1,1), def: (1,2))
        // audio: a line per channel (input and gain, or a meter) under its caption
        case .audio:        TileSpec(min: (1,2), def: (2,2))
        // shootingMode: caption + a value picker; recordedLUT, proxy: a toggle; assignable: a label opening its window
        case .shootingMode: TileSpec(min: (1,1), def: (2,2))
        case .recordedLUT, .proxy: TileSpec(min: (1,1), def: (1,2))
        case .assignable:   TileSpec(min: (1,1), def: (1,2))
        // steadyShot, imagerMode: caption + a value picker, as the ND mode's
        case .steadyShot, .imagerMode: TileSpec(min: (1,1), def: (2,2))
        // afSettings, clips: a button that opens its window, as Assignable's
        case .afSettings, .clips: TileSpec(min: (1,1), def: (1,2))
        // ecs: caption, the frequency and its − +; focus, zoom: two hold buttons either side of where it is
        case .ecs:          TileSpec(min: (1,2), def: (2,2))
        case .focusDrive, .zoomDrive: TileSpec(min: (2,2), def: (2,2))
        }
    }

    /// A tile with an option set in edit mode: the ND tile's step buttons (`PageWidget.showsStep`).
    public var takesStep: Bool { self == .ndPreset }
}

/// Layout spec for one tile kind: the single source of truth for minimum and default grid sizes and the
/// `TileFrame` thresholds that control where switches go. Change here, and every call site changes with it.
public struct TileSpec: Sendable {
    /// Smallest grid size the tile can be resized to (columns × half-rows).
    public let minimumSize: (w: Int, h: Int)
    /// Size when the tile is added from the palette (columns × half-rows).
    public let defaultSize: (w: Int, h: Int)
    /// Width (pt) at which the tile's mode switches move to their own trailing column.
    /// nil: the tile has no switches or always uses header placement.
    public let trailingFrom: CGFloat?
    /// Height (pt) at which the tile's mode switches move to a footer row (when not wide enough for trailing).
    /// nil: the tile has no switches or footer placement isn't used.
    public let footerFrom: CGFloat?
    /// Height (pt) below which the tile collapses to one line. Defaults to `Theme.oneLineBelow` (≈49pt).
    public let oneLineBelow: CGFloat?
    /// Width (pt) below which a one-line tile drops its caption, for a tile whose glyph says what it is: beside the
    /// caption its value would shrink past reading. nil: the caption always shows.
    public let captionFrom: CGFloat?

    public init(min: (w: Int, h: Int), def: (w: Int, h: Int),
                trailingFrom: CGFloat? = nil, footerFrom: CGFloat? = nil,
                oneLineBelow: CGFloat? = nil, captionFrom: CGFloat? = nil) {
        self.minimumSize = min
        self.defaultSize = def
        self.trailingFrom = trailingFrom
        self.footerFrom = footerFrom
        self.oneLineBelow = oneLineBelow
        self.captionFrom = captionFrom
    }
}

/// A page's grid cell as drawn: its width, its half-row's height and the gap between cells, in points.
public struct GridCellShape: Equatable, Sendable {
    public var cellWidth: Double
    public var rowHeight: Double
    public var gap: Double

    public init(cellWidth: Double, rowHeight: Double, gap: Double) {
        self.cellWidth = cellWidth
        self.rowHeight = rowHeight
        self.gap = gap
    }

    /// The half-rows a tile `columns` wide needs to show a 16:9 picture across its width (two at least).
    public func halfRows(forPictureAcross columns: Int) -> Int {
        let width = Double(columns) * cellWidth + Double(max(columns - 1, 0)) * gap
        return max(2, Int(((width * 9 / 16 + gap) / max(rowHeight + gap, 1)).rounded()))
    }
}

/// The one monitoring output a tile switches its overlay on (a Blackmagic camera's SDI), picked in edit mode.
public struct TileOutput: Codable, Hashable, Sendable {
    /// The camera's name for it, e.g. "MainSDI" (`MonitorOutput.id`).
    public var id: String
    /// As shown, e.g. "SDI": kept with the tile, so it says which output it's for while the camera is offline.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ output: MonitorOutput) {
        self.init(id: output.id, name: output.name)
    }
}

/// A tile placed on a page's grid. Positions are in columns and half-rows, so two half-height tiles can
/// stack in one standard tile's space.
public struct PageWidget: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: WidgetKind
    public var cameraID: UUID
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    /// For a monitoring switch (`WidgetKind.monitorOverlay`): the one output it switches; nil for every output. Absent
    /// from what's saved when nil, so a layout without one reads the same in builds from before it existed. With
    /// several outputs (`outputs`), the first of them: a build from before several existed then switches that one.
    public var output: TileOutput?
    /// Several outputs a monitoring switch works together (e.g. the LUT on SDI 1/2 and SDI 3/4, not the monitor).
    /// Nil unless two or more are chosen; `targets` reads both fields.
    public var outputs: [TileOutput]?

    /// The outputs this tile switches: several, one, or none for every output.
    public var targets: [TileOutput] { outputs ?? output.map { [$0] } ?? [] }
    /// The ND tile's − + step buttons, switched in edit mode: nil until someone does, which is `stepByDefault`.
    /// Absent from what's saved until switched, so a layout reads the same in builds from before it existed.
    public var showsStep: Bool?

    /// What an ND tile nobody has switched shows: no step buttons (the ND − and ND + tiles are the big
    /// ones, and the list is a tap on the value). Tiles someone has switched keep what they chose.
    public static let stepByDefault = false

    /// Whether this tile shows its step buttons (`showsStep`, else `stepByDefault`).
    public var stepButtons: Bool { showsStep ?? Self.stepByDefault }

    public init(id: UUID = UUID(), kind: WidgetKind, cameraID: UUID, x: Int, y: Int, w: Int, h: Int,
                output: TileOutput? = nil, outputs: [TileOutput]? = nil) {
        self.id = id
        self.kind = kind
        self.cameraID = cameraID
        self.x = x
        self.y = y
        self.w = max(w, 1)
        self.h = max(h, 1)
        self.output = output ?? outputs?.first
        self.outputs = (outputs?.count ?? 0) > 1 ? outputs : nil
    }

    /// Sets the outputs: none is every output, one is that output, several are those.
    public mutating func setTargets(_ chosen: [TileOutput]) {
        output = chosen.first
        outputs = chosen.count > 1 ? chosen : nil
    }

    public var maxX: Int { x + w }
    public var maxY: Int { y + h }

    public func overlaps(_ other: PageWidget) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// A customized page: a fixed number of columns and as many half-rows as the tiles need.
public struct PageLayout: Codable, Hashable, Sendable {
    public var columns: Int
    public var widgets: [PageWidget]

    public init(columns: Int, widgets: [PageWidget]) {
        self.columns = max(columns, 1)
        self.widgets = widgets
    }

    /// Half-rows in use. The grid grows with its content rather than having a fixed height.
    public var rows: Int { widgets.map(\.maxY).max() ?? 0 }

    /// Cameras on the page in reading order of their first tile (top row first, then left to right), so
    /// side-by-side blocks read A, B and a block added underneath comes last.
    public var cameraIDs: [UUID] {
        var first: [UUID: (Int, Int)] = [:]
        for widget in widgets {
            let key = (widget.y, widget.x)
            if let current = first[widget.cameraID], current <= key { continue }
            first[widget.cameraID] = key
        }
        return first.sorted { $0.value < $1.value }.map(\.key)
    }

    /// In bounds and not overlapping any other tile.
    public func fits(_ widget: PageWidget) -> Bool {
        widget.x >= 0 && widget.y >= 0 && widget.maxX <= columns
            && !widgets.contains { $0.id != widget.id && $0.overlaps(widget) }
    }

    /// First free spot for a `w`×`h` tile, scanning top to bottom, left to right. Always succeeds: past the
    /// last row everything is free.
    public func firstFreeSpot(w: Int, h: Int) -> (x: Int, y: Int) {
        firstFreeSpot(w: w, h: h, in: 0..<columns)
    }

    /// The same, but only in `span`'s columns (a camera's own, on a page of several), if the tile fits across them.
    public func firstFreeSpot(w: Int, h: Int, in span: Range<Int>) -> (x: Int, y: Int) {
        let span = span.clamped(to: 0..<columns)
        let width = min(max(w, 1), columns)
        guard span.count >= width else { return firstFreeSpot(w: w, h: h) }
        for y in 0...rows {
            for x in span.lowerBound...(span.upperBound - width) {
                let probe = PageWidget(kind: .label, cameraID: UUID(), x: x, y: y, w: width, h: h)
                if fits(probe) { return (x, y) }
            }
        }
        return (span.lowerBound, rows)
    }

    /// The columns a camera's tiles take on this page, nil if it has none.
    public func columnSpan(of camera: UUID) -> Range<Int>? {
        let mine = widgets.filter { $0.cameraID == camera }
        guard let left = mine.map(\.x).min(), let right = mine.map(\.maxX).max() else { return nil }
        return left..<right
    }

    /// One camera's tiles on a grid of their own: as wide as the columns they take, moved to its top-left, and where that
    /// corner is on this page, so an edit made there comes back to the page. Nil if the camera has no tiles here.
    public func cropped(to camera: UUID) -> CameraArrangement? {
        let mine = widgets.filter { $0.cameraID == camera }
        guard let span = columnSpan(of: camera), let top = mine.map(\.y).min() else { return nil }
        let moved = mine.map { var tile = $0; tile.x -= span.lowerBound; tile.y -= top; return tile }
        return CameraArrangement(layout: PageLayout(columns: span.count, widgets: moved),
                                 origin: GridSpot(x: span.lowerBound, y: top))
    }

    /// Every tile of one kind as another, in place.
    func replacingKind(_ kind: WidgetKind, with replacement: WidgetKind) -> PageLayout {
        var layout = self
        layout.widgets = widgets.map { var widget = $0; if widget.kind == kind { widget.kind = replacement }; return widget }
        return layout
    }

    /// Same tiles in the same places, ignoring tile identity: how a layout nobody changed is recognized as the
    /// automatic one it was copied from. A tile set to one output is a change: the templates never set one.
    public func sameArrangement(as other: PageLayout) -> Bool {
        // A tile's options count: an ND tile someone switched isn't the automatic one, or Done would drop the page back to
        // automatic and the switch with it (NDStepTests).
        func key(_ widget: PageWidget) -> String {
            "\(widget.kind.rawValue) \(widget.cameraID) \(widget.x) \(widget.y) \(widget.w) \(widget.h)"
                + widget.targets.map { " \($0.id)" }.sorted().joined()
                + (widget.showsStep.map { " step=\($0)" } ?? "")
        }
        return columns == other.columns && widgets.map(key).sorted() == other.widgets.map(key).sorted()
    }

    // Lenient decoding: a tile kind this build doesn't know (written by a newer build) is dropped rather
    // than failing the whole page.
    private enum CodingKeys: String, CodingKey { case columns, widgets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = max(try container.decode(Int.self, forKey: .columns), 1)
        widgets = try container.decode([Lenient<PageWidget>].self, forKey: .widgets).compactMap(\.value)
    }
}

/// One element of a saved list that this build may not be able to read (written by a newer build): nil rather than
/// failing the whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The built-in arrangements, as explicit placements. The automatic renderer draws these same shapes;
/// customizing a page starts from them.
public enum LayoutTemplates {
    /// Columns one camera takes in each style.
    public static let narrowColumns = 2
    public static let wideColumns = 4

    /// A template: (kind, x, y, w, h) per tile, in half-rows.
    typealias Cells = [(WidgetKind, Int, Int, Int, Int)]

    /// The built-in arrangements, by version. Only `current` is drawn; older sets let a migration recognize a
    /// saved layout nobody changed (a copy of what the app showed back then) and let it follow the new defaults.
    struct TemplateSet {
        var narrow: Cells
        var wide: Cells
        var fx3: Cells
        /// A Blackmagic camera's wide block; nil in older sets, which gave it `wide`.
        var blackmagic: Cells? = nil
        /// A VENICE's wide block; nil in older sets, which gave it `wide`.
        var venice: Cells? = nil
        /// An ARRI camera's wide block; nil in older sets, which gave it `wide`.
        var arri: Cells? = nil
    }

    /// Before changing a shipped block, copy the set as it shipped into a `vN` below and drop untouched layouts built from
    /// it in `Snapshot.migrated()` (as v2 and v3 are).
    static let current = TemplateSet(narrow: narrowCells, wide: wideCells, fx3: fx3Cells, blackmagic: blackmagicCells,
                                     venice: veniceCells, arri: arriCells)

    /// An ARRI camera's 4-wide block (ALEXA Mini first): what its Web Remote sets, laid out as the VENICE's. Identity
    /// with battery over media, latency over HaLow; REC, EI, the shutter dial and value over the WB preset; ND with
    /// ND − and ND + beside it, then sensor fps; sensor mode, codec and de-squeeze; the WB sliders (Kelvin and CC);
    /// the lens's iris (read off LDS), in a row of its own that goes with no lens; the look (which one, and on or off
    /// on every output) beside frame lines and false color; zebra, peaking, overlays and the per-output window;
    /// playback across the bottom. What a body doesn't report drops out and the gaps close.
    static let arriCells: Cells = [
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
        (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
        (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
        (.wbPreset, 3, 4, 1, 2),
        // ND − and ND + beside ND, as on the VENICE's.
        (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
        (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
        (.wbSliders, 0, 9, 4, 3),
        (.iris, 0, 12, 4, 2),
        (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
        (.zebra, 0, 16, 1, 2), (.focusAssist, 1, 16, 1, 2), (.statusText, 2, 16, 1, 2), (.monitoring, 3, 16, 1, 2),
        (.playback, 0, 18, 4, 2),
    ]

    /// A VENICE / VENICE 2's 4-wide block. Identity with battery over media, latency over HaLow; REC, EI (base ISO
    /// switch inside), the shutter dial and value over the WB preset; ND with ND − and ND + beside it, then Select FPS;
    /// the imager mode, the codec and de-squeeze; the WB sliders; iris in a row of its own, which goes with a lens
    /// that doesn't report (most PL glass); the look beside frame lines and false color; status text, the per-output
    /// window, the one-taps (color bars, sensor flip); playback across the bottom. The Web GUI tile is in Add Tile
    /// only. Whatever this body doesn't report drops out and the gaps close.
    static let veniceCells: Cells = [
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
        (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
        (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
        (.wbPreset, 3, 4, 1, 2),
        // The ND tile's own Step − + are off unless switched on, so ND − and ND + are on the page beside it.
        (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
        (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
        (.wbSliders, 0, 9, 4, 3),
        (.iris, 0, 12, 4, 2),
        (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
        (.statusText, 0, 16, 1, 2), (.monitoring, 1, 16, 1, 2), (.colorBars, 2, 16, 1, 2), (.sensorFlip, 3, 16, 1, 2),
        (.playback, 0, 18, 4, 2),
    ]

    /// A Blackmagic camera's 4-wide block: identity with battery over media, latency over HaLow; REC, ISO, the dial
    /// and the shutter value; frame rate, resolution, codec over the de-squeeze, and dynamic range in a row; the WB
    /// sliders beside the WB preset; iris for a lens the camera drives, in a row of its own; ND with ND − and ND + on
    /// a body with filters, in the row under it (the ND tile's own Step − + are off unless switched); the outputs' LUT,
    /// False Color, Frame Guides and Monitoring Options; Playback beside Naming. A PYXIS has neither iris nor ND
    /// without a lens the camera drives; both rows close.
    static let blackmagicCells: Cells = [
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
        (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 4),
        (.frameRate, 0, 6, 1, 2), (.resolution, 1, 6, 1, 2), (.codec, 2, 6, 1, 1), (.desqueeze, 2, 7, 1, 1),
        (.dynamicRange, 3, 6, 1, 2),
        (.wbSliders, 0, 8, 3, 3), (.wbPreset, 3, 8, 1, 3),
        (.iris, 0, 11, 4, 2),
        (.ndPreset, 0, 13, 2, 2), (.ndMinus, 2, 13, 1, 2), (.ndPlus, 3, 13, 1, 2),
        (.viewAssist, 0, 15, 1, 2), (.falseColor, 1, 15, 1, 2), (.frameGuides, 2, 15, 1, 2), (.monitoring, 3, 15, 1, 2),
        (.playback, 0, 17, 3, 2), (.clipName, 3, 17, 1, 2),
    ]

    /// The 2-wide column: name, battery over media, then timecode next to latency; WB preset over focus beside
    /// the sliders, so there's no hole under the preset; REC full width at the bottom.
    static let narrowCells: Cells = [
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1),
        (.timecode, 0, 2, 1, 2), (.latency, 1, 2, 1, 2),
        (.ndPreset, 0, 4, 2, 2),
        (.ndMinus, 0, 6, 1, 2), (.ndPlus, 1, 6, 1, 2),
        (.shutterDial, 0, 8, 1, 4), (.frameRate, 1, 8, 1, 4),
        (.iso, 0, 12, 2, 4),
        (.wbPreset, 0, 16, 1, 2), (.focusMode, 0, 18, 1, 2), (.wbSliders, 1, 16, 1, 4),
        (.iris, 0, 20, 2, 2),
        (.lut, 0, 22, 2, 2),
        // LUT and False Color on every output, for a camera with monitoring outputs (Blackmagic).
        (.viewAssist, 0, 24, 1, 2), (.falseColor, 1, 24, 1, 2),
        (.codec, 0, 26, 1, 2), (.bitrate, 1, 26, 1, 2),
        // Playback over REC: REC stays last, where a thumb reaches (as in the iPhone's automatic column). Five half-rows,
        // so that with three or four cameras on a page REC isn't its smallest button.
        (.playback, 0, 28, 2, 2),
        (.record, 0, 30, 2, 5),
    ]

    /// The 4-wide block, for every camera but the FX3 family (which gets `fx3`). No Web GUI, color bars or sensor
    /// flip (VENICE web-control features). View Assist only for a camera with monitoring outputs (`shows`): a
    /// Blackmagic camera's LUT and False Color on every output, beside its monitoring window. Tiles a camera doesn't
    /// report drop out and the gaps close (`closingGaps`).
    static let wideCells: Cells = [
        // Identity: name, battery over media, timecode (clip name under it), latency.
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1), (.latency, 3, 0, 1, 2),
        // REC + exposure
        (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
        (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
        // Frame rate, then ND with ND − and ND + beside it: the ND tile's own Step − + are off unless switched.
        (.frameRate, 0, 6, 1, 2), (.ndPreset, 1, 6, 1, 2), (.ndMinus, 2, 6, 1, 2), (.ndPlus, 3, 6, 1, 2),
        // Codec and bitrate, two columns each: a one-line caption and value need the width.
        (.codec, 0, 8, 2, 1), (.bitrate, 2, 8, 2, 1),
        // De-squeeze (Sony) or dynamic range (Blackmagic) beside the resolution: whichever is there takes the half.
        (.resolution, 0, 9, 2, 1), (.desqueeze, 2, 9, 1, 1), (.dynamicRange, 3, 9, 1, 1),
        (.wbSliders, 0, 10, 4, 3),
        (.iris, 0, 13, 4, 2),
        (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        (.viewAssist, 0, 17, 1, 2), (.falseColor, 1, 17, 1, 2), (.monitoring, 2, 17, 2, 2),
        (.playback, 0, 19, 4, 2),
    ]

    /// Tiles from a template. Their IDs come from the camera and the tile, not at random: an automatic page is laid
    /// out afresh on every redraw, and new IDs each time made SwiftUI rebuild every tile whenever a camera reported,
    /// closing any open picker (on iPad they never opened) and dropping a slider mid-drag.
    static func place(_ cells: Cells, camera: UUID, x x0: Int, y y0: Int) -> [PageWidget] {
        var seen: [WidgetKind: Int] = [:]
        return cells.map { cell in
            let n = seen[cell.0, default: 0]
            seen[cell.0] = n + 1
            return PageWidget(id: templateID(camera: camera, kind: cell.0, occurrence: n), kind: cell.0, cameraID: camera,
                              x: x0 + cell.1, y: y0 + cell.2, w: cell.3, h: cell.4)
        }
    }

    /// The same UUID every time for a camera's nth tile of a kind (name-based, RFC 4122 version 3).
    static func templateID(camera: UUID, kind: WidgetKind, occurrence: Int) -> UUID {
        var name = withUnsafeBytes(of: camera.uuid) { Data($0) }
        name.append(contentsOf: "\(kind.rawValue)#\(occurrence)".utf8)
        var b = Array(Insecure.MD5.hash(data: name))
        b[6] = (b[6] & 0x0F) | 0x30
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public static func narrow(camera: UUID, x: Int = 0, y: Int = 0) -> [PageWidget] {
        place(narrowCells, camera: camera, x: x, y: y)
    }

    public static func wide(camera: UUID, x: Int = 0, y: Int = 0) -> [PageWidget] {
        place(wideCells, camera: camera, x: x, y: y)
    }

    /// What an automatic page shows for these cameras, as an explicit layout. `wide` picks the 4-wide block per
    /// camera, otherwise the 2-wide column; by default one or two cameras are wide. With `state`, each block
    /// follows its camera: see `block`.
    public static func materialize(cameraIDs: [UUID], wide: Bool? = nil,
                                   profile: (UUID) -> CameraProfile? = { _ in nil }) -> PageLayout {
        materialize(cameraIDs: cameraIDs, wide: wide, profile: profile, templates: current)
    }

    /// Cameras side by side in columns line up row by row: a row of the column template that any of them has a tile
    /// in stays in every column, empty where a camera hasn't that control, and only rows none of them uses close up.
    /// So each control is the same size and on the same row across the page, and every REC ends the page at the same
    /// size. Without this, each column closes up on its own and the shorter columns' REC grows to the page's bottom:
    /// beside an FX5 showing False Color, an FX3's and an FX30's would be nearly twice its size.
    static func materialize(cameraIDs: [UUID], wide: Bool? = nil, profile: (UUID) -> CameraProfile?,
                            templates: TemplateSet) -> PageLayout {
        let isWide = wide ?? (cameraIDs.count <= 2)
        let span = isWide ? wideColumns : narrowColumns
        let held: Set<Int> = isWide || cameraIDs.count < 2 ? [] : Set(cameraIDs.flatMap { camera -> [Int] in
            let column = place(templates.narrow, camera: camera, x: 0, y: 0)
            guard let profile = profile(camera) else { return strips(column).map(\.top) }
            return strips(column).filter { $0.tiles.contains { shows($0.kind, profile: profile) } }.map(\.top)
        })
        var widgets: [PageWidget] = []
        for (index, camera) in cameraIDs.enumerated() {
            widgets += block(camera: camera, profile: profile(camera), wide: isWide, x: index * span, templates: templates,
                             holding: held)
        }
        return PageLayout(columns: max(cameraIDs.count, 1) * span, widgets: widgets)
    }

    /// One camera's block on an automatic page. An FX3 gets its own block when there's room for a wide one.
    /// Once the camera has reported, tiles for controls it doesn't have are dropped and the block re-packed
    /// strip by strip (no placeholders). `profile` is the camera's current or last report; nil means unknown.
    public static func block(camera: UUID, profile: CameraProfile?, wide: Bool, x: Int = 0, y: Int = 0) -> [PageWidget] {
        block(camera: camera, profile: profile, wide: wide, x: x, y: y, templates: current)
    }

    static func block(camera: UUID, profile: CameraProfile?, wide: Bool, x: Int = 0, y: Int = 0,
                      templates: TemplateSet, holding held: Set<Int> = []) -> [PageWidget] {
        let cells = !wide ? templates.narrow
            : profile?.isFX3Family == true ? templates.fx3
            : profile?.make == .blackmagic ? templates.blackmagic ?? templates.wide
            : profile?.isVenice == true ? templates.venice ?? templates.wide
            : profile?.make == .arri ? templates.arri ?? templates.wide
            : templates.wide
        let widgets = place(cells, camera: camera, x: x, y: y)
        guard let profile else { return widgets }
        return closingGaps(in: widgets, keeping: { shows($0.kind, profile: profile) },
                           columns: wide ? wideColumns : narrowColumns, x: x, holding: held)
    }

    /// Whether an automatic page shows a template's tile: the camera has the control, and View Assist only on a camera
    /// with monitoring outputs (Blackmagic, VENICE, ARRI), where it's the LUT on every output. The FX3's is the LUT
    /// tile's On switch, or Gamma Display Assist on a body without a LUT tile, and no such page had it; an FX6's or
    /// FX5's LUT outputs are monitoring outputs, but its LUT tile's Outputs switch is the same switch, so it doesn't get
    /// one either.
    static func shows(_ kind: WidgetKind, profile: CameraProfile) -> Bool {
        profile.offered.contains(kind)
            && (kind != .viewAssist || (profile.offered.contains(.monitoring) && !profile.isSonyProBody))
    }

    /// A customized page as it's shown: tiles `keeping` rejects (controls their camera doesn't have) are left
    /// out, and each camera's tiles close up within that camera's own columns, so the page has no holes where a
    /// control is missing and cameras stay where the user put them. Cameras whose blocks interleave just lose the tiles.
    public static func closingGaps(in layout: PageLayout, keeping keep: (PageWidget) -> Bool) -> PageLayout {
        var result: [PageWidget] = []
        for (_, widgets) in Dictionary(grouping: layout.widgets, by: \.cameraID) {
            guard let left = widgets.map(\.x).min(), let right = widgets.map(\.maxX).max() else { continue }
            result += closingGaps(in: widgets, keeping: keep, columns: right - left, x: left)
        }
        let closed = PageLayout(columns: layout.columns, widgets: result)
        guard closed.widgets.allSatisfy({ closed.fits($0) }) else {
            return PageLayout(columns: layout.columns, widgets: layout.widgets.filter(keep))
        }
        return closed
    }

    /// Drops the tiles `keeping` rejects and closes the gaps they leave, touching nothing else. Strips (runs of rows
    /// no tile crosses) that keep all their tiles stay exactly as arranged, holes and all, so a page reads as it was
    /// edited; a strip left empty disappears and the strips below move up. In a strip that lost some tiles, each stack
    /// of tiles (same column) stays a stack and moves left into freed columns, a stack that lost a tile lets the rest
    /// fill its height, and the last stack takes any columns left over.
    /// `holding`: strips (by their top row) left in place when empty, as another camera's column has them.
    static func closingGaps(in widgets: [PageWidget], keeping keep: (PageWidget) -> Bool,
                            columns: Int, x x0: Int, holding held: Set<Int> = []) -> [PageWidget] {
        var result: [PageWidget] = []
        var lift = 0
        for strip in strips(widgets) {
            let top = strip.top - lift
            let height = strip.bottom - strip.top
            let kept = strip.tiles.filter(keep)
            if kept.isEmpty {
                if !held.contains(strip.top) { lift += height }
                continue
            }
            if kept.count == strip.tiles.count {
                result += kept.map { var moved = $0; moved.y -= lift; return moved }
                continue
            }
            var stacks: [[PageWidget]] = []
            var cursor = x0
            for (_, stack) in Dictionary(grouping: strip.tiles, by: \.x).sorted(by: { $0.key < $1.key }) {
                let kept = stack.filter(keep).sorted { $0.y < $1.y }
                guard let width = kept.map(\.w).max() else { continue }
                // Re-stack from the strip's top; the last tile fills down to the strip's bottom.
                var placed: [PageWidget] = []
                var y = top
                for (index, tile) in kept.enumerated() {
                    var moved = tile
                    moved.x = cursor
                    moved.y = y
                    if index == kept.count - 1 { moved.h = top + height - y }
                    y += moved.h
                    placed.append(moved)
                }
                stacks.append(placed)
                cursor += width
            }
            let spare = x0 + columns - cursor
            if spare > 0 {
                stacks[stacks.count - 1] = stacks[stacks.count - 1].map { var wider = $0; wider.w += spare; return wider }
            }
            result += stacks.flatMap { $0 }
        }
        return result
    }

    /// Tiles cut into strips, runs of rows no tile crosses, top to bottom.
    static func strips(_ widgets: [PageWidget]) -> [(top: Int, bottom: Int, tiles: [PageWidget])] {
        var strips: [(top: Int, bottom: Int, tiles: [PageWidget])] = []
        for widget in widgets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if let last = strips.last, widget.y < last.bottom {
                strips[strips.count - 1].tiles.append(widget)
                strips[strips.count - 1].bottom = max(last.bottom, widget.maxY)
            } else {
                strips.append((widget.y, widget.maxY, [widget]))
            }
        }
        return strips
    }

    /// A camera joining a customized page gets a block below everything else, in whichever style fits the
    /// page's width.
    public static func appendingBlock(for camera: UUID, to layout: PageLayout) -> PageLayout {
        var result = layout
        let y = layout.rows
        // A page saved from this camera's automatic layout already holds its template IDs.
        let taken = Set(layout.widgets.map(\.id))
        result.widgets += (layout.columns >= wideColumns ? wide(camera: camera, y: y) : narrow(camera: camera, y: y)).map {
            var widget = $0
            if taken.contains(widget.id) { widget.id = UUID() }
            return widget
        }
        return result
    }

    /// What an iPhone shows for one camera that has no arrangement of its own: the camera's 2-wide column, changed only
    /// where the page was. Tiles the page took off the camera's automatic block come off the column (the gaps close),
    /// and tiles the page added follow the column's own, under the same ids. So a page customized in landscape or on
    /// an iPad keeps the phone's design (REC last, Playback full width) instead of a reflow of the big block, and
    /// customizing one camera doesn't rearrange another's.
    ///
    /// `wide`: the camera's 4-wide block instead, changed the same way: a phone on its side, for a page whose own
    /// arrangement of the camera is the 2-wide column, far too tall for that height (`shortScreen`).
    public static func phone(camera: UUID, profile: CameraProfile?, page: PageLayout?, wide: Bool = false) -> PageLayout {
        let columns = wide ? wideColumns : narrowColumns
        var column = PageLayout(columns: columns, widgets: block(camera: camera, profile: profile, wide: wide))
        guard let page else { return column }
        let mine = page.widgets.filter { $0.cameraID == camera }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        // The page's automatic block for this camera, in the style the page holds it (4-wide or 2-wide).
        let span = (mine.map(\.maxX).max() ?? 0) - (mine.map(\.x).min() ?? 0)
        let baseline = block(camera: camera, profile: profile, wide: span >= wideColumns)
        let mineIDs = Set(mine.map(\.id)), baselineIDs = Set(baseline.map(\.id))
        func count(_ kind: WidgetKind, _ tiles: [PageWidget]) -> Int { tiles.filter { $0.kind == kind }.count }

        var dropped: Set<UUID> = []
        for kind in Set(baseline.map(\.kind)) {
            let missing = count(kind, baseline) - count(kind, mine)
            guard missing > 0 else { continue }
            let tiles = column.widgets.filter { $0.kind == kind }
            // The column's own twin of the tile the page lost goes first.
            dropped.formUnion((tiles.filter { !mineIDs.contains($0.id) } + tiles.filter { mineIDs.contains($0.id) })
                .prefix(missing).map(\.id))
        }
        column.widgets = closingGaps(in: column.widgets, keeping: { !dropped.contains($0.id) }, columns: columns, x: 0)

        var added: [PageWidget] = []
        for kind in Set(mine.map(\.kind)) {
            let extra = count(kind, mine) - count(kind, baseline)
            guard extra > 0 else { continue }
            let tiles = mine.filter { $0.kind == kind }
            added += (tiles.filter { !baselineIDs.contains($0.id) } + tiles.filter { baselineIDs.contains($0.id) }).prefix(extra)
        }
        for tile in added.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let size: (w: Int, h: Int) = wide ? (min(tile.kind.defaultSize.w, columns), tile.kind.defaultSize.h) : phoneSize(tile.kind)
            let spot = column.firstFreeSpot(w: size.w, h: size.h)
            column.widgets.append(PageWidget(id: tile.id, kind: tile.kind, cameraID: camera,
                                             x: spot.x, y: spot.y, w: size.w, h: size.h, output: tile.output,
                                             outputs: tile.outputs))
        }
        // The column's tiles are the page's, arranged for the phone: one the page set to an output (SDI) switches the
        // same output here.
        let targets = Dictionary(mine.map { ($0.id, $0.targets) }, uniquingKeysWith: { first, _ in first })
        for index in column.widgets.indices {
            if let chosen = targets[column.widgets[index].id], !chosen.isEmpty { column.widgets[index].setTargets(chosen) }
        }
        return column
    }

    /// What a short screen (a phone on its side) shows of one camera on a page of several, one camera at a time
    /// (four cameras side by side would leave every tile a sliver):
    /// - its part of the page, when that's at least a 4-wide block (a page of one or two cameras, customized or not, has
    ///   them side by side four columns each). On a customized page its `origin` takes edits made on it back to the page.
    /// - Otherwise (three or more cameras, two columns each and far too tall for the height) its 4-wide block, changed
    ///   where the page was (`phone(camera:profile:page:wide:)`). Its tiles are the page's, but it isn't the page's
    ///   arrangement, so nothing is edited through it (no `origin`).
    /// An automatic page is cut from its wide arrangement, which entering edit mode makes the page's own for two cameras.
    public static func shortScreen(camera: UUID, cameras: [UUID], profile: (UUID) -> CameraProfile?,
                                   page: PageLayout?) -> CameraArrangement {
        let derived = CameraArrangement(layout: phone(camera: camera, profile: profile(camera), page: page, wide: true),
                                        origin: nil)
        guard let page else {
            let automatic = materialize(cameraIDs: cameras, wide: true, profile: profile)
            guard let crop = automatic.cropped(to: camera) else { return derived }
            return CameraArrangement(layout: crop.layout, origin: nil)
        }
        guard let crop = page.cropped(to: camera), crop.layout.columns >= wideColumns else { return derived }
        return crop
    }

    /// A tile's size in an iPhone column: at most the column's two widths, and never a lone half row, which on a
    /// phone is too short to read or hit.
    public static func phoneSize(_ kind: WidgetKind) -> (w: Int, h: Int) {
        (min(kind.defaultSize.w, narrowColumns), max(kind.defaultSize.h, 2))
    }

    /// One camera's tiles reflowed into two columns. Widths scale with the camera's own block: a 4-wide block halves
    /// them, a 2-wide column keeps them. Builds before 8 showed a customized page on an iPhone this way; migrations
    /// use it to recognize the copies of it that were saved.
    static func compact(_ layout: PageLayout, camera: UUID) -> PageLayout {
        let mine = layout.widgets.filter { $0.cameraID == camera }
        guard let left = mine.map(\.x).min(), let right = mine.map(\.maxX).max() else {
            return PageLayout(columns: 2, widgets: [])
        }
        let packed = reflow(mine, columns: 2, scale: 2 / Double(max(right - left, 1)))
        return PageLayout(columns: 2, widgets: growingLoneHalfRows(packed, original: mine))
    }

    /// A half-row tile is fine stacked under another (timecode over clip name), but one that ends up beside
    /// another on a phone is a half row of an already narrow screen: unreadable (the FX3 page's status tile).
    /// Rows holding only such tiles grow to a full row; everything below moves down.
    static func growingLoneHalfRows(_ widgets: [PageWidget], original: [PageWidget]) -> [PageWidget] {
        // Stack partners come from the original layout: half-row tiles in one column, one under the other.
        // Position alone would pair unrelated tiles that happen to land one above the other.
        var partner: [UUID: UUID] = [:]
        for upper in original where upper.h == 1 {
            if let lower = original.first(where: { $0.h == 1 && $0.x == upper.x && $0.y == upper.y + 1 }) {
                partner[upper.id] = lower.id
                partner[lower.id] = upper.id
            }
        }
        func isLone(_ widget: PageWidget, in all: [PageWidget]) -> Bool {
            guard widget.h == 1 else { return false }
            guard let mateID = partner[widget.id], let mate = all.first(where: { $0.id == mateID }) else { return true }
            return !(mate.x == widget.x && abs(mate.y - widget.y) == 1)
        }
        var result = widgets
        let starts = Set(result.map(\.y)).sorted(by: >)
        for row in starts {
            let starting = result.filter { $0.y == row }
            guard starting.contains(where: { $0.h == 1 }),
                  starting.allSatisfy({ $0.h >= 2 || isLone($0, in: result) }) else { continue }
            result = result.map { widget in
                var moved = widget
                if widget.y > row { moved.y += 1 }
                else if widget.y == row, widget.h == 1 { moved.h = 2 }
                else if widget.y + widget.h > row + 1 { moved.h += 1 }  // spans the new row
                return moved
            }
        }
        return result
    }

    /// Re-packs tiles into `columns` columns from (x, y). The tiles are cut into strips, runs of rows no tile
    /// crosses, and read strip by strip, each strip left to right. Tiles that sat together stay together (REC,
    /// ISO and shutter; then white balance; then format) instead of the left half of a block coming before the
    /// right half, and gaps left by dropped tiles close up. Widths are multiplied by `scale`, then clamped.
    static func reflow(_ widgets: [PageWidget], columns: Int, scale: Double, x x0: Int = 0, y y0: Int = 0) -> [PageWidget] {
        var strips: [[PageWidget]] = []
        var stripBottom = Int.min
        for widget in widgets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if widget.y >= stripBottom { strips.append([]) }
            strips[strips.count - 1].append(widget)
            stripBottom = max(stripBottom, widget.maxY)
        }
        var packed = PageLayout(columns: columns, widgets: [])
        for strip in strips {
            let top = packed.rows
            // Tiles stacked in one column (timecode over clip name, shutter over WB) move as a unit, so a stack stays
            // a stack and the next tile sits beside it: the FX3's name and camera info, then timecode and latency.
            for (_, stack) in Dictionary(grouping: strip, by: \.x).sorted(by: { $0.key < $1.key }) {
                let tiles = stack.sorted { $0.y < $1.y }
                let width = min(max(Int((Double(tiles.map(\.w).max() ?? 1) * scale).rounded()), 1), columns)
                let spot = firstSpot(in: packed, w: width, h: tiles.map(\.h).reduce(0, +), from: top)
                var y = spot.y
                for widget in tiles {
                    packed.widgets.append(PageWidget(id: widget.id, kind: widget.kind, cameraID: widget.cameraID,
                                                     x: spot.x, y: y, w: width, h: widget.h, output: widget.output,
                                                     outputs: widget.outputs))
                    y += widget.h
                }
            }
        }
        return packed.widgets.map { var moved = $0; moved.x += x0; moved.y += y0; return moved }
    }

    // MARK: - FX3 template

    /// A 4-wide single-camera layout for the FX3 family. The FX3 doesn't offer resolution (0xD024) or de-squeeze
    /// (0xE0A4) over the network protocol (resolution comes with the codec), so neither is here.
    ///
    /// Strips, in half-rows: identity (2), REC + exposure (4), WB sliders (3), iris (2), frame rate + codec (4),
    /// LUT + focus (2). Identity strip: name, camera info, timecode, latency, all one size. The next clip's name sits
    /// under bitrate, with the other recording settings.
    static let fx3Cells: Cells = [
        (.label, 0, 0, 1, 2), (.battery, 1, 0, 1, 1), (.media, 1, 1, 1, 1), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 2),
        (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
        (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
        (.wbSliders, 0, 6, 4, 3),
        (.iris, 0, 9, 4, 2),
        // Frame rate gives up half its height (it changes between setups, not during takes) to Playback, so
        // reviewing a take is on the first page.
        (.frameRate, 0, 11, 2, 2), (.codec, 2, 11, 2, 2), (.playback, 0, 13, 2, 2),
        (.bitrate, 2, 13, 2, 1), (.clipName, 2, 14, 2, 1),
        (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
    ]

    public static func fx3(camera: UUID, x: Int = 0, y: Int = 0) -> [PageWidget] {
        place(fx3Cells, camera: camera, x: x, y: y)
    }

    /// First free spot at or below row `top`, scanning top to bottom, left to right.
    private static func firstSpot(in layout: PageLayout, w: Int, h: Int, from top: Int) -> (x: Int, y: Int) {
        for y in top...(layout.rows + 1) {
            for x in 0...(layout.columns - w) {
                let probe = PageWidget(kind: .label, cameraID: UUID(), x: x, y: y, w: w, h: h)
                if layout.fits(probe) { return (x, y) }
            }
        }
        return (0, max(layout.rows, top))
    }
}

// MARK: - What a camera offers

/// What a camera turned out to be: its model and the tiles it has controls for. Live from `CameraState` while it
/// reports, and saved with the camera so an automatic page keeps its shape while the camera is offline.
public struct CameraProfile: Codable, Hashable, Sendable {
    public var model: String?
    public var offered: Set<WidgetKind>
    /// Who made it: a Blackmagic camera gets its own block (`LayoutTemplates.blackmagicCells`).
    public var make: ProfileCameraType?
    /// Its monitoring outputs (a Blackmagic camera's LCD, USB-C monitors, SDI), so edit mode can offer them while it's
    /// offline. Nil for a camera without them, or one last seen by a build before they were kept.
    public var outputs: [TileOutput]?
    /// The LUTs a Blackmagic camera has been seen using: its LUT picker's options, kept between connections because the
    /// camera only ever names the one in use. Nil for a camera that names them all (Sony) or hasn't named one yet.
    public var luts: [String]?

    public init(model: String?, offered: Set<WidgetKind>, make: ProfileCameraType? = nil, outputs: [TileOutput]? = nil,
                luts: [String]? = nil) {
        self.model = model
        self.offered = offered
        self.make = make
        self.outputs = outputs
        self.luts = luts
    }

    /// FX3, FX3A and FX30 share the FX3's controls and get its block.
    public var isFX3Family: Bool { CameraProfile.isFX3Family(model) }

    /// True for FX3, FX3A, and FX30: the FX3 template family.
    public static func isFX3Family(_ model: String?) -> Bool { model?.contains("FX3") == true }

    /// An FX6 or FX5, whose LUT outputs are monitoring outputs.
    public var isSonyProBody: Bool { SonyProBody.has(model) }

    /// A VENICE or VENICE 2 (MPC-3610 / MPC-3628, or the name itself): its own block (`LayoutTemplates.veniceCells`).
    public var isVenice: Bool { CameraProfile.isVenice(model) }

    public static func isVenice(_ model: String?) -> Bool {
        guard let m = model?.uppercased() else { return false }
        return m.contains("VENICE") || m.contains("MPC-3610") || m.contains("MPC-3628") || m.contains("MPC-3626")
    }

    /// True for FX3 and FX3A only (not FX30): these bodies take Tiles' bundled false color LUT.
    public static func takesFalseColorLUT(_ model: String?) -> Bool {
        guard let m = model?.uppercased() else { return false }
        return m.hasSuffix("FX3") || m.hasSuffix("FX3A")
    }

    private enum CodingKeys: String, CodingKey { case model, offered, make, outputs, luts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        // A tile kind from a newer version is dropped rather than failing the whole saved setup.
        let raw = try container.decodeIfPresent([String].self, forKey: .offered) ?? []
        offered = Set(raw.compactMap(WidgetKind.init(rawValue:)))
        make = try container.decodeIfPresent(ProfileCameraType.self, forKey: .make)
        outputs = try? container.decodeIfPresent([TileOutput].self, forKey: .outputs)
        luts = try? container.decodeIfPresent([String].self, forKey: .luts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(offered.map(\.rawValue).sorted(), forKey: .offered)
        try container.encodeIfPresent(make, forKey: .make)
        try container.encodeIfPresent(outputs, forKey: .outputs)
        try container.encodeIfPresent(luts, forKey: .luts)
    }
}

extension CameraState {
    /// The camera has reported its properties. Until then nothing can be said about what it offers.
    public var hasReported: Bool { recording.state != .unknown }

    /// Whether the camera has the control behind a tile. The app's own tiles (letter, status, latency) and REC
    /// always count. A nil field means the body doesn't have that control (see `CameraState`).
    public func offers(_ kind: WidgetKind) -> Bool {
        switch kind {
        // The timecode tile shows REC time when a camera reports no timecode (no Sony body does over PTP 3).
        case .label, .status, .battery, .media, .latency, .record, .timecode: true
        case .clipName: clipName != nil || fileNaming != nil
        case .ndPreset, .ndMinus, .ndPlus: nd != nil
        case .shutterDial, .shutterValue: shutterAngle != nil || shutterSpeed != nil
        case .frameRate: frameRate != nil
        case .iso: iso != nil || gain != nil
        case .wbPreset, .wbSliders: whiteBalance != nil
        case .iris: iris != nil
        case .format: recordingFormat != nil
        case .colorBars: colorBars != nil
        case .falseColor: falseColor != nil
        case .look, .viewAssist: look != nil
        case .sensorFlip: imageFlip != nil
        case .hdmiInfo: hdmiInfo != nil
        case .gridLines: gridLines != nil
        // Gone: its web page and Tiles connected at once trip a camera up. Kept as a kind only
        // so a saved Web GUI tile reads back, and comes off (`Snapshot.webGUIRemoved`).
        case .webGUI: false
        case .resolution: resolution != nil
        case .codec: fileFormat != nil
        case .bitrate: recordingSetting != nil
        case .desqueeze: desqueeze != nil
        case .lut: lut != nil
        case .focusMode: focusMode != nil
        // Always offered: it shows the HaLow node, not the camera (Settings → HaLow Nodes).
        case .haLow: true
        // The app's lock, whatever the camera has.
        case .lock: true
        case .liveView, .liveViewButton: hasLiveView
        case .playback: playback != nil
        case .dynamicRange: dynamicRange != nil
        case .monitoring: monitoring?.outputs.isEmpty == false
        case .zebra: monitoring?.onEverywhere(.zebra) != nil
        case .focusAssist: monitoring?.onEverywhere(.focusAssist) != nil
        case .frameGuides: monitoring?.onEverywhere(.frameGuides) != nil
        case .cleanFeed: monitoring?.onEverywhere(.cleanFeed) != nil
        case .statusText: monitoring?.onEverywhere(.statusText) != nil
        case .statusTextContent: monitoring?.outputs.contains { $0.statusTextContent != nil } == true
        case .ndMode: ndMode != nil
        case .tally: tally != nil
        case .call: call != nil
        case .colorGamut: colorGamut != nil
        case .cameraMenu: !cameraButtons.isEmpty
        case .autoFocus: canAutoFocus
        case .audio: !audioChannels.isEmpty || audioMeterCount > 0
        case .userFrameA: userFrameLinesA != nil
        case .userFrameB: userFrameLinesB != nil
        case .shootingMode: shootingMode != nil
        case .recordedLUT: recordedLUT != nil
        case .proxy: proxyRecording != nil
        case .ecs: ecs != nil
        case .focusDrive: focusDrive != nil
        case .zoomDrive: zoomDrive != nil
        case .assignable: !assignableButtons.isEmpty
        case .steadyShot: steadyShot != nil
        case .imagerMode: imagerMode != nil
        case .afSettings: hasAFSettings
        case .clips: playback?.capabilities.goToClip == true
        }
    }
}

// MARK: - Monitoring switches

/// What a one-tap monitoring tile shows (nil: grayed) and what a tap sends.
public struct MonitorSwitch {
    public var choice: Choice<Bool>?
    public var command: (Bool) -> CameraCommand
    /// Everything a tap sends: one command, or one per output for a tile set to several.
    public var commands: (Bool) -> [CameraCommand]

    public init(choice: Choice<Bool>?, command: @escaping (Bool) -> CameraCommand) {
        self.choice = choice
        self.command = command
        self.commands = { [command($0)] }
    }

    public init(choice: Choice<Bool>?, commands: @escaping (Bool) -> [CameraCommand]) {
        self.choice = choice
        self.commands = commands
        self.command = { commands($0).first ?? .setLook($0) }
    }
}

extension CameraState {
    /// The camera sets its overlays output by output (Blackmagic). True from connect, before its outputs have been read:
    /// `look` and `falseColor` are the first output's until then, and a tile set to one output mustn't take them for
    /// its own.
    public var setsOverlaysPerOutput: Bool { monitoring != nil || make == .blackmagic }

    /// A monitoring tile's switch: `overlay` on one output (`output`, its id), or with nil on every output, as the LUT,
    /// False Color, Zebra, Focus Assist and Frame Guides tiles always worked. A tile set to an output the camera doesn't
    /// have, or hasn't reported yet, is grayed: it never falls back to every output. On a camera without outputs (Sony)
    /// the LUT and False Color tiles are the camera's own switches, whatever output they carry.
    /// Several outputs at once: lit only when every one of them shows it (a tap turns it on where it's still off), grayed
    /// when none of them is on this camera; a tap goes to each output the camera has.
    public func monitorSwitch(_ overlay: MonitorOverlay, outputs ids: [String]) -> MonitorSwitch {
        guard ids.count > 1, setsOverlaysPerOutput else { return monitorSwitch(overlay, output: ids.first) }
        let chosen = (monitoring?.outputs ?? []).filter { ids.contains($0.id) && $0.overlays[overlay] != nil }
        let settings = chosen.compactMap { $0.setting(overlay) }
        let choice: Choice<Bool>? = settings.isEmpty ? nil
            : Choice(settings.allSatisfy(\.value), options: [false, true], isWritable: settings.contains(where: \.isWritable))
        let present = chosen.map(\.id)
        return MonitorSwitch(choice: choice, commands: { on in present.map { .setMonitorOverlay(overlay, on, output: $0) } })
    }

    public func monitorSwitch(_ overlay: MonitorOverlay, output: String?) -> MonitorSwitch {
        if let output, setsOverlaysPerOutput {
            return MonitorSwitch(choice: monitoring?.outputs.first { $0.id == output }?.setting(overlay),
                                 command: { .setMonitorOverlay(overlay, $0, output: output) })
        }
        switch overlay {
        case .lut: return MonitorSwitch(choice: look, command: { .setLook($0) })
        case .falseColor: return MonitorSwitch(choice: falseColor, command: { .setFalseColor($0) })
        default:
            return MonitorSwitch(choice: monitoring?.onEverywhere(overlay), command: { .setMonitorOverlay(overlay, $0, output: nil) })
        }
    }
}

extension MonitoringState {
    /// The outputs a tile for `overlay` can be set to: the ones that report it.
    public func outputs(showing overlay: MonitorOverlay) -> [MonitorOutput] {
        outputs.filter { $0.overlays[overlay] != nil }
    }

    /// The outputs a tile of `kind` can be set to: those with its overlay, or with a say in what status text shows.
    public func outputs(for kind: WidgetKind) -> [MonitorOutput] {
        if let overlay = kind.monitorOverlay { return outputs(showing: overlay) }
        return kind == .statusTextContent ? outputs.filter { $0.statusTextContent != nil } : []
    }

    /// The output a new tile of `kind` starts on. Clean feed and status text are for the picture going to a client or a
    /// recorder, which is the SDI out: on the LCD clean feed would hide the operator's own status and overlays. What
    /// status text shows is one output's, SDI's first. Every other overlay starts on every output (nil), as those tiles
    /// always worked.
    public func defaultOutput(for kind: WidgetKind) -> TileOutput? {
        guard [.cleanFeed, .statusText, .statusTextContent].contains(kind) else { return nil }
        let candidates = outputs(for: kind)
        let sdi = candidates.first { $0.id.localizedCaseInsensitiveContains("SDI") }
        return (sdi ?? (kind == .statusTextContent ? candidates.first : nil)).map(TileOutput.init)
    }
}

extension LayoutTemplates {
    // v2: pre-reorder identity-strip order (timecode first). Kept for migration only.
    static let v2 = TemplateSet(
        narrow: [
            (.timecode, 0, 0, 1, 2), (.label, 1, 0, 1, 2), (.ndPreset, 0, 2, 2, 2), (.ndMinus, 0, 4, 1, 2),
            (.ndPlus, 1, 4, 1, 2), (.shutterDial, 0, 6, 1, 4), (.frameRate, 1, 6, 1, 4), (.iso, 0, 10, 2, 4),
            (.wbPreset, 0, 14, 1, 2), (.wbSliders, 1, 14, 1, 4), (.iris, 0, 18, 2, 2), (.lut, 0, 20, 2, 2),
            (.focusMode, 0, 22, 1, 2), (.status, 1, 22, 1, 2), (.codec, 0, 24, 1, 2), (.bitrate, 1, 24, 1, 2),
            (.record, 0, 26, 2, 3),
        ],
        wide: [
            (.label, 0, 0, 1, 2), (.timecode, 1, 0, 1, 1), (.clipName, 1, 1, 1, 1), (.frameRate, 2, 0, 1, 2),
            (.ndPreset, 3, 0, 1, 2), (.record, 0, 2, 1, 2), (.shutterValue, 1, 2, 1, 1), (.wbPreset, 1, 3, 1, 1),
            (.iso, 2, 2, 1, 2), (.shutterDial, 3, 2, 1, 2), (.status, 0, 4, 1, 1), (.latency, 0, 5, 1, 1),
            (.codec, 1, 4, 2, 1), (.bitrate, 1, 5, 2, 1), (.resolution, 3, 4, 1, 1), (.desqueeze, 3, 5, 1, 1),
            (.wbSliders, 0, 6, 4, 3), (.iris, 0, 9, 4, 2), (.lut, 0, 11, 3, 2), (.focusMode, 3, 11, 1, 2),
        ],
        fx3: [
            (.label, 0, 0, 1, 2), (.timecode, 1, 0, 2, 2), (.status, 3, 0, 1, 1), (.latency, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2), (.wbSliders, 0, 6, 4, 3), (.iris, 0, 9, 4, 2), (.frameRate, 0, 11, 2, 4),
            (.codec, 2, 11, 2, 2), (.bitrate, 2, 13, 2, 2), (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        ]
    )

    // v3: reordered identity-strip and focusMode. Kept for migration only (v6 resets untouched v3 layouts).
    static let v3 = TemplateSet(
        narrow: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2),
            (.timecode, 0, 2, 1, 2), (.latency, 1, 2, 1, 2),
            (.ndPreset, 0, 4, 2, 2),
            (.ndMinus, 0, 6, 1, 2), (.ndPlus, 1, 6, 1, 2),
            (.shutterDial, 0, 8, 1, 4), (.frameRate, 1, 8, 1, 4),
            (.iso, 0, 12, 2, 4),
            (.wbPreset, 0, 16, 1, 2), (.focusMode, 0, 18, 1, 2), (.wbSliders, 1, 16, 1, 4),
            (.iris, 0, 20, 2, 2),
            (.lut, 0, 22, 2, 2),
            (.codec, 0, 24, 1, 2), (.bitrate, 1, 24, 1, 2),
            (.record, 0, 26, 2, 3),
        ],
        wide: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.frameRate, 0, 6, 1, 2), (.ndPreset, 1, 6, 1, 2), (.codec, 2, 6, 2, 1), (.bitrate, 2, 7, 2, 1),
            (.resolution, 0, 8, 2, 1), (.desqueeze, 2, 8, 2, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 3, 2), (.focusMode, 3, 14, 1, 2),
        ],
        fx3: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.wbSliders, 0, 6, 4, 3),
            (.iris, 0, 9, 4, 2),
            (.frameRate, 0, 11, 2, 4), (.codec, 2, 11, 2, 2), (.bitrate, 2, 13, 2, 2),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        ]
    )

    // v4: the 4-wide blocks before ND − and ND + joined every one with an ND tile.
    // Kept for migration only (v9 resets untouched v4 layouts).
    static let v4 = TemplateSet(
        narrow: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2),
            (.timecode, 0, 2, 1, 2), (.latency, 1, 2, 1, 2),
            (.ndPreset, 0, 4, 2, 2),
            (.ndMinus, 0, 6, 1, 2), (.ndPlus, 1, 6, 1, 2),
            (.shutterDial, 0, 8, 1, 4), (.frameRate, 1, 8, 1, 4),
            (.iso, 0, 12, 2, 4),
            (.wbPreset, 0, 16, 1, 2), (.focusMode, 0, 18, 1, 2), (.wbSliders, 1, 16, 1, 4),
            (.iris, 0, 20, 2, 2),
            (.lut, 0, 22, 2, 2),
            (.viewAssist, 0, 24, 1, 2), (.falseColor, 1, 24, 1, 2),
            (.codec, 0, 26, 1, 2), (.bitrate, 1, 26, 1, 2),
            (.playback, 0, 28, 2, 2),
            (.record, 0, 30, 2, 3),
        ],
        wide: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.frameRate, 0, 6, 1, 2), (.ndPreset, 1, 6, 1, 2), (.codec, 2, 6, 2, 1), (.bitrate, 2, 7, 2, 1),
            (.resolution, 0, 8, 2, 1), (.desqueeze, 2, 8, 1, 1), (.dynamicRange, 3, 8, 1, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 3, 2), (.focusMode, 3, 14, 1, 2),
            (.viewAssist, 0, 16, 1, 2), (.falseColor, 1, 16, 1, 2), (.monitoring, 2, 16, 2, 2),
            (.playback, 0, 18, 4, 2),
        ],
        fx3: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.wbSliders, 0, 6, 4, 3),
            (.iris, 0, 9, 4, 2),
            (.frameRate, 0, 11, 2, 2), (.codec, 2, 11, 2, 2), (.playback, 0, 13, 2, 2),
            (.bitrate, 2, 13, 2, 1), (.clipName, 2, 14, 2, 1),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        ],
        blackmagic: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 4),
            (.frameRate, 0, 6, 1, 2), (.resolution, 1, 6, 1, 2), (.codec, 2, 6, 1, 2), (.dynamicRange, 3, 6, 1, 2),
            (.wbSliders, 0, 8, 3, 3), (.wbPreset, 3, 8, 1, 3),
            (.iris, 0, 11, 3, 2), (.ndPreset, 3, 11, 1, 2),
            (.viewAssist, 0, 13, 1, 2), (.falseColor, 1, 13, 1, 2), (.frameGuides, 2, 13, 1, 2), (.monitoring, 3, 13, 1, 2),
            (.playback, 0, 15, 3, 2), (.clipName, 3, 15, 1, 2),
        ],
        venice: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.frameRate, 1, 6, 1, 2), (.resolution, 2, 6, 1, 1), (.codec, 2, 7, 1, 1),
            (.desqueeze, 3, 6, 1, 2),
            (.wbSliders, 0, 8, 4, 3),
            (.iris, 0, 11, 4, 2),
            (.lut, 0, 13, 2, 2), (.frameGuides, 2, 13, 1, 2), (.falseColor, 3, 13, 1, 2),
            (.statusText, 0, 15, 1, 2), (.monitoring, 1, 15, 1, 2), (.colorBars, 2, 15, 1, 2), (.sensorFlip, 3, 15, 1, 2),
            (.playback, 0, 17, 4, 2),
        ],
        arri: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.frameRate, 1, 6, 1, 2), (.resolution, 2, 6, 1, 1), (.codec, 2, 7, 1, 1),
            (.desqueeze, 3, 6, 1, 2),
            (.wbSliders, 0, 8, 4, 3),
            (.iris, 0, 11, 4, 2),
            (.lut, 0, 13, 2, 2), (.frameGuides, 2, 13, 1, 2), (.falseColor, 3, 13, 1, 2),
            (.zebra, 0, 15, 1, 2), (.focusAssist, 1, 15, 1, 2), (.statusText, 2, 15, 1, 2), (.monitoring, 3, 15, 1, 2),
            (.playback, 0, 17, 3, 2), (.webGUI, 3, 17, 1, 2),
        ]
    )

    // v5: the blocks before De-squeeze joined the Blackmagic block (under Codec).
    // Kept for migration only (v10 resets untouched v5 layouts).
    static let v5 = TemplateSet(
        narrow: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2),
            (.timecode, 0, 2, 1, 2), (.latency, 1, 2, 1, 2),
            (.ndPreset, 0, 4, 2, 2),
            (.ndMinus, 0, 6, 1, 2), (.ndPlus, 1, 6, 1, 2),
            (.shutterDial, 0, 8, 1, 4), (.frameRate, 1, 8, 1, 4),
            (.iso, 0, 12, 2, 4),
            (.wbPreset, 0, 16, 1, 2), (.focusMode, 0, 18, 1, 2), (.wbSliders, 1, 16, 1, 4),
            (.iris, 0, 20, 2, 2),
            (.lut, 0, 22, 2, 2),
            (.viewAssist, 0, 24, 1, 2), (.falseColor, 1, 24, 1, 2),
            (.codec, 0, 26, 1, 2), (.bitrate, 1, 26, 1, 2),
            (.playback, 0, 28, 2, 2),
            (.record, 0, 30, 2, 3),
        ],
        wide: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.frameRate, 0, 6, 1, 2), (.ndPreset, 1, 6, 1, 2), (.ndMinus, 2, 6, 1, 2), (.ndPlus, 3, 6, 1, 2),
            (.codec, 0, 8, 2, 1), (.bitrate, 2, 8, 2, 1),
            (.resolution, 0, 9, 2, 1), (.desqueeze, 2, 9, 1, 1), (.dynamicRange, 3, 9, 1, 1),
            (.wbSliders, 0, 10, 4, 3),
            (.iris, 0, 13, 4, 2),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
            (.viewAssist, 0, 17, 1, 2), (.falseColor, 1, 17, 1, 2), (.monitoring, 2, 17, 2, 2),
            (.playback, 0, 19, 4, 2),
        ],
        fx3: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.wbSliders, 0, 6, 4, 3),
            (.iris, 0, 9, 4, 2),
            (.frameRate, 0, 11, 2, 2), (.codec, 2, 11, 2, 2), (.playback, 0, 13, 2, 2),
            (.bitrate, 2, 13, 2, 1), (.clipName, 2, 14, 2, 1),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        ],
        blackmagic: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 4),
            (.frameRate, 0, 6, 1, 2), (.resolution, 1, 6, 1, 2), (.codec, 2, 6, 1, 2), (.dynamicRange, 3, 6, 1, 2),
            (.wbSliders, 0, 8, 3, 3), (.wbPreset, 3, 8, 1, 3),
            (.iris, 0, 11, 4, 2),
            (.ndPreset, 0, 13, 2, 2), (.ndMinus, 2, 13, 1, 2), (.ndPlus, 3, 13, 1, 2),
            (.viewAssist, 0, 15, 1, 2), (.falseColor, 1, 15, 1, 2), (.frameGuides, 2, 15, 1, 2), (.monitoring, 3, 15, 1, 2),
            (.playback, 0, 17, 3, 2), (.clipName, 3, 17, 1, 2),
        ],
        venice: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
            (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
            (.statusText, 0, 16, 1, 2), (.monitoring, 1, 16, 1, 2), (.colorBars, 2, 16, 1, 2), (.sensorFlip, 3, 16, 1, 2),
            (.playback, 0, 18, 4, 2),
        ],
        arri: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
            (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
            (.zebra, 0, 16, 1, 2), (.focusAssist, 1, 16, 1, 2), (.statusText, 2, 16, 1, 2), (.monitoring, 3, 16, 1, 2),
            (.playback, 0, 18, 4, 2),
        ]
    )

    // v6: the blocks before Battery and Media became their own tiles (replacing the combined Battery / Media tile
    // in the identity strip). Kept for migration only (v11 resets untouched v6 layouts).
    static let v6 = TemplateSet(
        narrow: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2),
            (.timecode, 0, 2, 1, 2), (.latency, 1, 2, 1, 2),
            (.ndPreset, 0, 4, 2, 2),
            (.ndMinus, 0, 6, 1, 2), (.ndPlus, 1, 6, 1, 2),
            (.shutterDial, 0, 8, 1, 4), (.frameRate, 1, 8, 1, 4),
            (.iso, 0, 12, 2, 4),
            (.wbPreset, 0, 16, 1, 2), (.focusMode, 0, 18, 1, 2), (.wbSliders, 1, 16, 1, 4),
            (.iris, 0, 20, 2, 2),
            (.lut, 0, 22, 2, 2),
            (.viewAssist, 0, 24, 1, 2), (.falseColor, 1, 24, 1, 2),
            (.codec, 0, 26, 1, 2), (.bitrate, 1, 26, 1, 2),
            (.playback, 0, 28, 2, 2),
            (.record, 0, 30, 2, 3),
        ],
        wide: [
            // Identity: name, camera info (Battery / Media), timecode (clip name under it), latency.
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.frameRate, 0, 6, 1, 2), (.ndPreset, 1, 6, 1, 2), (.ndMinus, 2, 6, 1, 2), (.ndPlus, 3, 6, 1, 2),
            (.codec, 0, 8, 2, 1), (.bitrate, 2, 8, 2, 1),
            (.resolution, 0, 9, 2, 1), (.desqueeze, 2, 9, 1, 1), (.dynamicRange, 3, 9, 1, 1),
            (.wbSliders, 0, 10, 4, 3),
            (.iris, 0, 13, 4, 2),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
            (.viewAssist, 0, 17, 1, 2), (.falseColor, 1, 17, 1, 2), (.monitoring, 2, 17, 2, 2),
            (.playback, 0, 19, 4, 2),
        ],
        fx3: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 2),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4),
            (.shutterValue, 3, 2, 1, 2), (.wbPreset, 3, 4, 1, 2),
            (.wbSliders, 0, 6, 4, 3),
            (.iris, 0, 9, 4, 2),
            (.frameRate, 0, 11, 2, 2), (.codec, 2, 11, 2, 2), (.playback, 0, 13, 2, 2),
            (.bitrate, 2, 13, 2, 1), (.clipName, 2, 14, 2, 1),
            (.lut, 0, 15, 3, 2), (.focusMode, 3, 15, 1, 2),
        ],
        blackmagic: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 2), (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 4),
            (.frameRate, 0, 6, 1, 2), (.resolution, 1, 6, 1, 2), (.codec, 2, 6, 1, 1), (.desqueeze, 2, 7, 1, 1),
            (.dynamicRange, 3, 6, 1, 2),
            (.wbSliders, 0, 8, 3, 3), (.wbPreset, 3, 8, 1, 3),
            (.iris, 0, 11, 4, 2),
            (.ndPreset, 0, 13, 2, 2), (.ndMinus, 2, 13, 1, 2), (.ndPlus, 3, 13, 1, 2),
            (.viewAssist, 0, 15, 1, 2), (.falseColor, 1, 15, 1, 2), (.frameGuides, 2, 15, 1, 2), (.monitoring, 3, 15, 1, 2),
            (.playback, 0, 17, 3, 2), (.clipName, 3, 17, 1, 2),
        ],
        venice: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
            (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
            (.statusText, 0, 16, 1, 2), (.monitoring, 1, 16, 1, 2), (.colorBars, 2, 16, 1, 2), (.sensorFlip, 3, 16, 1, 2),
            (.playback, 0, 18, 4, 2),
        ],
        arri: [
            (.label, 0, 0, 1, 2), (.status, 1, 0, 1, 2), (.timecode, 2, 0, 1, 1), (.clipName, 2, 1, 1, 1),
            (.latency, 3, 0, 1, 1), (.haLow, 3, 1, 1, 1),
            (.record, 0, 2, 1, 4), (.iso, 1, 2, 1, 4), (.shutterDial, 2, 2, 1, 4), (.shutterValue, 3, 2, 1, 2),
            (.wbPreset, 3, 4, 1, 2),
            (.ndPreset, 0, 6, 1, 2), (.ndMinus, 1, 6, 1, 2), (.ndPlus, 2, 6, 1, 2), (.frameRate, 3, 6, 1, 2),
            (.resolution, 0, 8, 2, 1), (.codec, 2, 8, 1, 1), (.desqueeze, 3, 8, 1, 1),
            (.wbSliders, 0, 9, 4, 3),
            (.iris, 0, 12, 4, 2),
            (.lut, 0, 14, 2, 2), (.frameGuides, 2, 14, 1, 2), (.falseColor, 3, 14, 1, 2),
            (.zebra, 0, 16, 1, 2), (.focusAssist, 1, 16, 1, 2), (.statusText, 2, 16, 1, 2), (.monitoring, 3, 16, 1, 2),
            (.playback, 0, 18, 4, 2),
        ]
    )
}

/// One camera's part of a page on a grid of its own (`PageLayout.cropped(to:)`, `LayoutTemplates.shortScreen`).
public struct CameraArrangement: Equatable, Sendable {
    public var layout: PageLayout
    /// Where the arrangement's top-left is on the page, when an edit made on it goes back to the page; nil when it's
    /// drawn from the templates and can't be edited through.
    public var origin: GridSpot?

    public init(layout: PageLayout, origin: GridSpot?) {
        self.layout = layout
        self.origin = origin
    }
}

/// Sony's pro bodies whose own controls Tiles reads (shooting mode, gain and base sensitivity, proxy, AGC, the LUT
/// outputs, the lens drives, assignable buttons): the FX6 (docs/fx6-controls.md) and the FX5, which lists the same
/// codes and was checked with them (docs/fx5-controls.md, 2026-11-14). Not a BURANO: it lists several, unchecked.
public enum SonyProBody {
    /// "ILME-FX6V", "ILME-FX5".
    public static func has(_ model: String?) -> Bool {
        guard let model else { return false }
        return model.contains("FX6") || model.contains("FX5")
    }
}
