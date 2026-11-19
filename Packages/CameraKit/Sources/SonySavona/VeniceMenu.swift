import Foundation

/// VENICE 2's full-menu items as its own web page defines them (WebMenu.js, camera FW V4.00): the
/// value a `P.System.Menu.…` property reads and takes, and the name the camera shows. The camera's capability lists
/// (`P.System.Menu.L3_…`) give the item indices that are allowed right now, e.g. only 13–23 (the 8.6K modes) on an
/// MPC-3628.
public enum VeniceMenu {
    public struct Item: Sendable, Equatable {
        public let index: Int
        public let value: Int
        public let label: String
    }

    static func items(_ rows: [(Int, Int, String)]) -> [Item] { rows.map { Item(index: $0.0, value: $0.1, label: $0.2) } }

    /// P.System.Menu.CamImagermode; allowed: P.System.Menu.L3_IMAGER_MODE.
    public static let imagerModes = items([
        (0, 1, "6K 3:2"), (1, 3, "6K 1.85:1"), (2, 4, "6K 17:9"), (3, 5, "6K 2.39:1"), (4, 6, "5.7K 16:9"),
        (5, 7, "4K 6:5"), (6, 10, "4K 4:3"), (7, 11, "4K 4:3 Surround View"), (8, 12, "4K 17:9"),
        (9, 13, "4K 17:9 Surround View"), (10, 16, "4K 2.39:1"), (11, 14, "3.8K 16:9"), (12, 15, "3.8K 16:9 Surround View"),
        (13, 17, "8.6K 3:2"), (14, 18, "8.6K 17:9"), (15, 20, "8.2K 17:9"), (16, 22, "8.2K 2.39:1"), (17, 19, "8.1K 16:9"),
        (18, 21, "7.6K 16:9"), (19, 25, "5.8K 6:5"), (20, 26, "5.8K 4:3"), (21, 27, "5.8K 17:9"), (22, 29, "5.5K 2.39:1"),
        (23, 28, "5.4K 16:9"),
    ])
    /// P.System.Menu.SystemFrequency (Project > Project Frame Rate); allowed: P.System.Menu.L3_SYSTEM_FRAME_RATE.
    public static let projectRates = items([
        (0, 5, "23.98"), (1, 6, "24"), (2, 4, "25"), (3, 3, "29.97"), (4, 7, "47.95"), (5, 2, "50"), (6, 1, "59.94"),
    ])
    /// P.System.Menu.AxsRecformatSelect; allowed: P.System.Menu.L3_AXS_MAIN_REC_FORMAT.
    public static let recordingFormats = items([
        (0, 0, "Rec Off"), (1, 4, "X-OCN XT"), (2, 1, "RAW SQ"), (3, 2, "X-OCN ST"), (4, 3, "X-OCN LT"),
        (5, 9, "ProRes 4444 XQ 4K"), (6, 10, "ProRes 4444 XQ QFHD"), (7, 5, "ProRes 4444 4K"), (8, 6, "ProRes 4444 QFHD"),
        (9, 7, "ProRes 422 HQ 4K"), (10, 8, "ProRes 422 HQ QFHD"),
    ])
    /// P.System.Menu.FlipImage (Monitoring > Output Display > Flip Image).
    public static let flipImage = items([(0, 0, "Normal"), (1, 2, "Horizontal Flip"), (2, 1, "Vertical Flip"), (3, 3, "H & V Flip")])
    /// P.System.Menu.ShutterMode (Technical > Shutter Mode): "0" Speed, "1" Angle.
    public static let shutterMode = items([(0, 0, "Speed"), (1, 1, "Angle")])
    /// P.System.Menu.RecOutDeanamoScaleSelect (Project > Anamo. De-Squeeze, the menu's L3_SXS_OUTPUT_DE_SQUEEZE). Its
    /// values aren't in display order: 1.6× is 6. The items allowed now: P.System.Menu.SxsOutputDeSqueeze.HighLightList,
    /// item indices (PulldownView.js grays the rest).
    public static let desqueeze = items([(0, 0, "Off"), (1, 1, "1.25x"), (2, 2, "1.3x"), (3, 3, "1.5x"), (4, 6, "1.6x"),
                                         (5, 4, "1.8x"), (6, 5, "2.0x")])
    /// P.System.Menu.ColorBar (Technical > Color Bars), and the menu item's lock.
    public static let colorBarProperty = "P.System.Menu.ColorBar"
    public static let colorBarLock = "P.System.Menu.ColorBar.MenuItem"

    public static let desqueezeProperty = "P.System.Menu.RecOutDeanamoScaleSelect"
    public static let desqueezeAllowed = "P.System.Menu.SxsOutputDeSqueeze.HighLightList"
    /// "1" while the menu shows Anamo. De-Squeeze at all (it needs the Anamorphic Lens license).
    public static let desqueezeVisible = "P.System.Menu.SxsOutputDeSqueeze.Visiable"

    /// Which output another follows (OutputFormatConverter.js, Const.js: OUTPUT_FORMAT_INFO_*). The camera derives it
    /// from the output formats and only reports it: SDI 3/4 can show the same as SDI 1/2 or the Monitor, the HDMI the
    /// same as SDI 1/2, SDI 1/2/3/4 or the Monitor. "4" (SDI 3/4, Monitor) and "5" (HDMI) are an output of its own.
    public static let followsSdi34 = "P.System.Menu.OutputFormat.Info.Sdi34"
    public static let followsMonitor = "P.System.Menu.OutputFormat.Info.Moni"
    public static let followsHdmi = "P.System.Menu.OutputFormat.Info.Hdmi"
    /// "1": the Monitor out shows the viewfinder's picture (Monitor Out Source: VF).
    public static let monitorOutSource = "P.System.Menu.MonitorOutSource"

    /// The output a follow code names, by Tiles' output id; nil for an output of its own.
    public static func followed(_ code: String?) -> String? {
        switch code {
        case "0": "Sdi12"
        case "1": "Sdi12"  // SDI 1/2/3/4: SDI 3/4 shows SDI 1/2's
        case "2": "Monitor"
        case "3": "Vf"
        default: nil
        }
    }

    /// The lock on a menu item, by the property Tiles writes (Property.GetStatus names them `….MenuItem`, after the
    /// menu's own item, which isn't always the property's name).
    public static let menuLocks: [String: String] = [
        imagerModeProperty: "P.System.Menu.ProjectImagerMode.MenuItem",
        recordingFormatProperty: "P.System.Menu.AxsrecformatSet.MenuItem",
        projectRateProperty: "P.System.Menu.FrequencySet.MenuItem",
        desqueezeProperty: "P.System.Menu.SxsOutputDeSqueeze.MenuItem",
        colorBarProperty: colorBarLock,
        "P.System.Menu.FlipImage": "P.System.Menu.FlipImage.MenuItem",
        "P.System.Menu.ClipnamingCameraid": "P.System.Menu.ClipNaming.MenuItem",
        "P.System.Menu.ClipnamingReelNum": "P.System.Menu.ClipNaming.MenuItem",
        "P.System.Menu.ClipnamingCameraposition": "P.System.Menu.CameraPosition.MenuItem",
        "Camera.Gain.ISOValue": "P.System.Menu.BaseIso.MenuItem",
    ]

    public static let imagerModeProperty = "P.System.Menu.CamImagermode"
    public static let imagerModeAllowed = "P.System.Menu.L3_IMAGER_MODE"
    public static let projectRateProperty = "P.System.Menu.SystemFrequency"
    public static let projectRateAllowed = "P.System.Menu.L3_SYSTEM_FRAME_RATE"
    public static let recordingFormatProperty = "P.System.Menu.AxsRecformatSelect"
    public static let recordingFormatAllowed = "P.System.Menu.L3_AXS_MAIN_REC_FORMAT"
    public static let shutterModeProperty = "P.System.Menu.ShutterMode"

    /// The name for a value the camera reads ("17" → "8.6K 3:2"); nil for a value the table doesn't have.
    public static func label(_ items: [Item], value: MPValue?) -> String? {
        guard let number = value?.unwrapped.number else { return nil }
        return items.first { $0.value == Int(number) }?.label
    }

    /// The value to write for a name ("8.6K 3:2" → "17").
    public static func value(_ items: [Item], label: String) -> String? {
        items.first { $0.label == label }.map { String($0.value) }
    }

    /// The names the camera allows now, from its capability list of item indices; every name without one.
    public static func labels(_ items: [Item], allowed: [MPValue]?) -> [String] {
        let indices = (allowed ?? []).compactMap { $0.number.map { Int($0) } }
        guard !indices.isEmpty else { return items.map(\.label) }
        return indices.compactMap { index in items.first { $0.index == index }?.label }
    }
}
