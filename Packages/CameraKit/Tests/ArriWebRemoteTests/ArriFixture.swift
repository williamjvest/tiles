import Foundation

/// An ALEXA Mini as Tiles expects its Web Remote to read: the variable names known to be on the cameras, in the shapes
/// the camera sends them, plus the backend's first guesses for the rest
/// (CameraState, Timecode, the per-output switches). Synthetic: no camera's serial, clips or settings. Replace the
/// guesses with the real names after the first session (docs/arri.md, "Capture day").
enum ArriFixture {
    static func variables() -> [String: [String: Any]] {
        func enumint(_ value: Int, _ count: Int, flags: [Int]? = nil, readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "enumint", "min": 0, "max": count - 1,
             "properties": flags ?? Array(repeating: 3, count: count), "readonly": readonly ? 1 : 0]
        }
        func float(_ value: Double, _ min: Double, _ max: Double, readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "float", "min": min, "max": max, "readonly": readonly ? 1 : 0]
        }
        func int(_ value: Int, readonly: Bool = true) -> [String: Any] {
            ["value": value, "type": "int", "readonly": readonly ? 1 : 0]
        }
        func bool(_ value: Bool, readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "bool", "readonly": readonly ? 1 : 0]
        }
        func string(_ value: String) -> [String: Any] {
            ["value": value, "type": "string", "readonly": 1]
        }
        return [
            "SystemCameraType": string("ALEXA Mini"),
            "SystemCameraSerial": string("K1.71234"),
            "CameraState": enumint(0, 3, readonly: true),
            "Timecode": string("14:22:01:12"),
            "ClipName": string("A004C012_261022_R1AB"),
            "ClipNameReelCount": ["value": 4, "type": "int", "min": 1, "max": 999, "readonly": 0],
            "SystemCameraIndex": enumint(0, 26),
            "ExposureIndex": enumint(7, 14),
            "ActExposureIndexIso": int(800),
            "NDFilterPosition": enumint(1, 4),
            "NDFilterPositionEffective": enumint(1, 4, readonly: true),
            "WBCurrentKelvin": float(5600, 2000, 11000),
            "WBCurrentColorComp": float(0, -16, 16),
            "ShutterNominal": float(172.8, 5, 356),
            "ExposurePreferenceIsAngle": bool(true),
            "FPSNominal": float(24, 0.75, 200),
            "FPSEffective": float(24, 0.75, 200, readonly: true),
            "SensorMode": enumint(0, 3),
            "RecCodec": enumint(0, 3, flags: [3, 3, 1]),
            "LookFile": enumint(0, 2),
            "LookSwitchEvf": bool(true), "LookSwitchSdi1": bool(true), "LookSwitchSdi2": bool(false),
            "FramelinesEvf": bool(true), "FramelinesSdi1": bool(true), "FramelinesSdi2": bool(false),
            "ExposureToolEvf": enumint(0, 3), "ExposureToolSdi1": enumint(0, 3), "ExposureToolSdi2": enumint(2, 3),
            "FocusToolEvf": enumint(1, 2), "FocusToolSdi1": enumint(0, 2),
            "OverlaysEvf": bool(true), "OverlaysSdi1": bool(false), "OverlaysSdi2": bool(true),
            "ZebraLevelEvf": ["value": 70, "type": "int", "min": 0, "max": 100, "readonly": 0],
            "TestImage": enumint(0, 2),
            "LensIris": int(3000),
            "LensModelName": string("Signature Prime 47mm"),
            "BatteryVoltage": float(15.2, 0, 36, readonly: true),
            "RemainingRecTime": int(38),
            "PlaybackSpeedEnum": enumint(10, 21),
            "PlaybackSpeed": int(0),
            "_PlaybackControlsAreActive": bool(false),
            "PlaybackClipIndex": int(-1),
            "ClipCountCardA": int(11),
            "ClipCountCardB": int(0),
            "ClipTableCardAVersion": int(3),
            "ClipTableCardBVersion": int(1),
        ]
    }

    static let recStart = "_fixtureRecStart"
    static let recStop = "_fixtureRecStop"
    static let skipBack = "_BJbzscJjEeSbpa7lQ8OAJw"
    static let skipForward = "_H_V7l8JjEeSbpa7lQ8OAJw"

    static let commands: [String: String] = [
        recStart: "RecordingStart",
        recStop: "RecordingStop",
        "_EeUkIwIBEeSgptigTra4vQ": "PlayBackPrepare",
        "_7q_F4cHREeStK8NH8ZPGbQ": "PlayBackGo",
        "__WRr68HREeStK8NH8ZPGbQ": "PlayBackStop",
        "_cCCFscHSEeStK8NH8ZPGbQ": "PlayBackEnd",
        skipBack: "PlayBackSkipClip",
        skipForward: "PlayBackSkipClip",
        "_4da_Ua3pEeSjhp9JjGKhGQ": "AutoWB",  // the page's AWB button (2026-10-29)
    ]

    static let eis = [160, 200, 250, 320, 400, 500, 640, 800, 1000, 1280, 1600, 2000, 2560, 3200]
    static let letters = (65...90).map { String(UnicodeScalar(UInt8($0))) }
    static let speeds = "REV_512 REV_256 REV_128 REV_64 REV_32 REV_16 REV_8 REV_4 REV_2 REV_1 PAUSE FWD_1 FWD_2 FWD_4 FWD_8 FWD_16 FWD_32 FWD_64 FWD_128 FWD_256 FWD_512"

    /// The page script's shapes: declarations, token lists (split strings and arrays), English labels.
    static let script: String = {
        var lines = ["var b={};"]
        let declared = [("ExposureIndex", "ExposureIndex"), ("NDFilterPosition", "NDFilter"),
                        ("NDFilterPositionEffective", "NDFilter"), ("PlaybackSpeedEnum", "PlaybackSpeed"),
                        ("SensorMode", "SensorMode"), ("RecCodec", "RecCodec"), ("LookFile", "LookFile"),
                        ("SystemCameraIndex", "CameraIndex"), ("CameraState", "CameraState"),
                        ("ExposureToolEvf", "ExposureTool"), ("ExposureToolSdi1", "ExposureTool"),
                        ("ExposureToolSdi2", "ExposureTool"), ("FocusToolEvf", "FocusTool"),
                        ("FocusToolSdi1", "FocusTool"), ("TestImage", "TestImage"), ("GuiMode", "GuiMode"),
                        ("SDI1Processing", "SDIProcessing"), ("SDI2Processing", "SDIProcessing")]
        for (name, type) in declared {
            lines.append("b.\(name)={name:\"\(name)\",value:\"X\",type:\"\(type)\"};")
        }
        // The page's dependency list for GuiMode, keyed by its name: page-model ids, which an ALEXA Mini's script has
        // before the enum's own list (a test adds the GuiMode variable itself).
        lines.append("var deps = {GuiMode:\"_aiYR0OjXEeSdT43XlOyQBg _IyoSkOjXEeSdT43XlOyQBg\".split(\" \")};")
        lines.append("""
            var enums = {
            ExposureIndex:"\(eis.map { "EI_\($0)" }.joined(separator: " "))".split(" "),
            NDFilter:["CLEAR","ZERO_POINT_SIX","ONE_POINT_TWO","TWO_POINT_ONE"],
            PlaybackSpeed:"\(speeds)".split(" "),
            SensorMode:["S_3_4K_OG","S_4_3_2_8K","S_16_9_HD"],
            RecCodec:["ARRIRAW","PRORES_4444","PRORES_422_HQ"],
            LookFile:["L0","L1"],
            CameraIndex:"\(letters.joined(separator: " "))".split(" "),
            CameraState:["STANDBY","RECORDING","PLAYBACK"],
            ExposureTool:["OFF","FALSE_COLOR","ZEBRA"],
            FocusTool:["OFF","PEAKING"],
            TestImage:["OFF","COLOR_BARS"],
            GuiMode:["NORMAL","OVERLAY_MENU","PLAYBACK","ERASE"],
            SDIProcessing:["CLEAN","PROCESSED"]
            };
            var a = {en:{}};
            """)
        var labels: [(String, String)] = eis.map { ("ExposureIndex_EI_\($0)", "\($0)") }
        labels += [("NDFilter_CLEAR", "ND  -"), ("NDFilter_ZERO_POINT_SIX", "ND 0.6"),
                   ("NDFilter_ONE_POINT_TWO", "ND 1.2"), ("NDFilter_TWO_POINT_ONE", "ND 2.1")]
        labels += [("SensorMode_S_3_4K_OG", "3.4K Open Gate"), ("SensorMode_S_4_3_2_8K", "4:3 2.8K"),
                   ("SensorMode_S_16_9_HD", "16:9 HD")]
        labels += [("RecCodec_ARRIRAW", "ARRIRAW"), ("RecCodec_PRORES_4444", "ProRes 4444"),
                   ("RecCodec_PRORES_422_HQ", "ProRes 422 HQ")]
        labels += [("LookFile_L0", "ARRI 709"), ("LookFile_L1", "Toldwell Show Look")]
        labels += letters.map { ("CameraIndex_\($0)", $0) }
        labels += [("CameraState_STANDBY", "Standby"), ("CameraState_RECORDING", "Recording"),
                   ("CameraState_PLAYBACK", "Playback")]
        labels += [("ExposureTool_OFF", "Off"), ("ExposureTool_FALSE_COLOR", "False Color"),
                   ("ExposureTool_ZEBRA", "Zebra"), ("FocusTool_OFF", "Off"), ("FocusTool_PEAKING", "Peaking"),
                   ("TestImage_OFF", "Off"), ("TestImage_COLOR_BARS", "Color Bars"),
                   ("SDIProcessing_CLEAN", "Clean"), ("SDIProcessing_PROCESSED", "Processed")]
        for (key, label) in labels { lines.append("a.en.ENUM_\(key)=\"\(label)\";") }
        lines.append("a.en.ENUM_PlaybackSpeed_FWD_2=\"2x\";")
        return lines.joined(separator: "\n")
    }()
}
