import Foundation
import Testing
@testable import ArriWebRemote
@testable import CameraCore

// An original ALEXA Mini (SUP 6.1.2) as its Web Remote really reads: the names, types and shapes from the first
// capture of one (docs/alexa-mini-controls.md), values trimmed to what each test needs. No card, no LDS lens, as
// that camera was; the card and lens cases set them.

private enum Mini {
    static func variables() -> [String: [String: Any]] {
        func enumint(_ value: Int, _ count: Int, flags: [Int]? = nil, readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "enumint", "min": 0, "max": count - 1,
             "properties": flags ?? Array(repeating: 3, count: count), "readonly": readonly ? 1 : 0]
        }
        func float(_ value: Double, _ min: Double = -3.40282e38, _ max: Double = 3.40282e38,
                   readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "float", "min": min, "max": max, "readonly": readonly ? 1 : 0]
        }
        func int(_ value: Int, readonly: Bool = true) -> [String: Any] {
            ["value": value, "type": "int", "min": -2147483648, "max": 2147483647, "readonly": readonly ? 1 : 0]
        }
        func bool(_ value: Bool, readonly: Bool = false) -> [String: Any] {
            ["value": value, "type": "bool", "readonly": readonly ? 1 : 0]
        }
        func string(_ value: String) -> [String: Any] { ["value": value, "type": "string", "readonly": 1] }
        func array(_ rows: [[Any]]) -> [String: Any] { ["value": rows, "type": "array", "readonly": 1] }
        return [
            "SystemCameraType": int(2), "SystemCameraSerial": int(10001),
            "SystemSWMajor": int(6), "SystemSWMinor": int(1), "SystemSWPatch": int(2),
            "MajorState": enumint(2, 9, readonly: true), "RecordingIsPossible": bool(false, readonly: true),
            "GuiMode": enumint(0, 4),
            "TimecodeHours": int(0), "TimecodeMinutes": int(15), "TimecodeSeconds": int(32),
            "TCIsFreeRun_Effective": bool(true, readonly: true),
            "EVFStatusTimecodeIsOn": bool(true), "SDIStatusTimecodeIsOn": bool(false),
            "ExposureIndex": enumint(7, 14), "NDFilterPosition": enumint(2, 4),
            "WBCurrentKelvin": float(5000, 2000, 11000), "WBCurrentColorComp": float(0, -16, 16),
            "ShutterNominal": float(180, 5, 356), "ExposurePreferenceIsAngle": bool(true),
            "ShutterTable": array([[7, 45], [7, 90], [7, 144], [7, 172.8], [7, 180], [7, 270], [0, 0]]),
            "FPSNominal": float(24, 0.75, 50), "FPSEffective": float(24, readonly: true),
            "FPSTable": array([[7, 8], [7, 12], [7, 23.976], [7, 24], [7, 25], [7, 29.97], [7, 30], [7, 40], [7, 48],
                               [7, 50], [5, 59.94], [5, 60], [5, 100], [5, 120], [5, 144], [5, 200], [0, 0]]),
            "ProjectRate": enumint(1, 9),
            "SensorFormat": enumint(2, 3), "SensorFormatPrepare": enumint(1, 3),
            "RecCodecType": enumint(1, 3), "RecCodecTypePrepare": enumint(-1, 3),
            "LookActiveSlot": int(1, readonly: false),
            "Look1_Filename": string("ARRI 709.AML"), "Look2_Filename": string("FilmUnlimited_500Tv2.aml"),
            "LensSqueezeFactor": enumint(0, 3), "SensorImageFlip": enumint(0, 4),
            "LDSIrisFullStops": enumint(0, 21, readonly: true), "LDSIrisSubStops": int(0),
            "LDSIrisSubStopsScaleInt": int(10), "LDSIrisValue": int(-1),
            "ButtonLensIrisShallLock": bool(false), "EVFStatusLensFocusIsOn": bool(false),
            "Bat1LevelPercent": int(0), "Bat1CapacityState": enumint(0, 3, readonly: true),
            "Bat1LevelVolt": float(0, readonly: true), "Bat2LevelVolt": float(14.848, readonly: true),
            "CardAStatus": enumint(0, 14, readonly: true), "CardBStatus": enumint(0, 14, readonly: true),
            "CardBIsSelected": bool(true), "CardACapacityRemain_Raw": int(0), "CardBCapacityRemain_Raw": int(0),
            "CameraIndex": enumint(0, 26), "ReelCountCardA": int(0),
            "EVFTestImageIsActive": bool(false), "SDI1TestImageIsActive": bool(false),
            // Outputs: the look per path, the rest shared by both SDI outputs.
            "SDI1PathProcessing": enumint(1, 3), "SDI2PathProcessing": enumint(1, 3, flags: [1, 3, 1]),
            // SDI 1 and 2 image, as on the bench: SDI 1 Processed, so SDI 2 can only be Clean (or a clone of SDI 1).
            "SDI1Processing": enumint(1, 2), "SDI2Processing": enumint(0, 2, flags: [3, 1]),
            "SDI1ProcessingOptions": int(2), "SDI2IsSDI1Clone": bool(false),
            "EVFMonitorPathProcessing": enumint(1, 3), "EVFMonitorPathProcessingEffective": enumint(1, 3, readonly: true),
            "SDIFramelinesAreOn": bool(true), "SDIExposureToolIsOn": bool(false), "SDIExposureTool": enumint(1, 2),
            "SDIPeakingIsOn": bool(false), "SDIPeakingModeIsAperture": bool(false), "SDIStatusInfo1IsOn": bool(true),
            "EVFFramelinesAreOn": bool(true), "EVFExposureToolIsOn": bool(true), "EVFPeakingIsOn": bool(false),
            "EVFStatusInfo1IsOn": bool(true),
            "MonitorFramelineIsOn": bool(true), "MonitorExposureToolIsOn": bool(true), "MonitorPeakingIsOn": bool(false),
            "MonitorStatusInfo1IsOn": bool(true), "MonitorExtControlOverlaysAreHidden": bool(false),
            "MessageEventLookSDIColorSpaceChanged": bool(false), "MessageEventLookEVFProcessingChanged": bool(false),
        ]
    }

    /// The enums these tests read, in the page script's shapes (the Mini's own tokens and labels).
    static let script: String = {
        let declared = [("MajorState", "MajorState"), ("GuiMode", "GuiMode"), ("ExposureIndex", "ExposureIndex"),
                        ("NDFilterPosition", "NDFilter"), ("ProjectRate", "ProjectRate"),
                        ("SensorFormat", "SensorFormat"), ("SensorFormatPrepare", "SensorFormat"),
                        ("RecCodecType", "CodecType"), ("RecCodecTypePrepare", "CodecType"),
                        ("LensSqueezeFactor", "LensSqueeze"), ("SensorImageFlip", "ImageFlip"),
                        ("LDSIrisFullStops", "IrisFullStops"), ("Bat1CapacityState", "BatCapacityState"),
                        ("CardAStatus", "CardStatus"), ("CardBStatus", "CardStatus"), ("CameraIndex", "Character"),
                        ("SDI1PathProcessing", "PathProcessing"), ("SDI2PathProcessing", "PathProcessing"),
                        ("EVFMonitorPathProcessing", "PathProcessing"),
                        ("EVFMonitorPathProcessingEffective", "PathProcessing"),
                        ("SDIExposureTool", "ExposureTool"), ("SDI1Processing", "SDIProcessing"),
                        ("SDI2Processing", "SDIProcessing")]
        var lines = ["var c={};"] + declared.map { "c.\($0.0)={name:\"\($0.0)\",value:\"X\",type:\"\($0.1)\"};" }
        // The page's dependency list for GuiMode comes first, in the split spelling, as in the Mini's script.
        lines.append("var d={GuiMode:\"_aiYR0OjXEeSdT43XlOyQBg _IyoSkOjXEeSdT43XlOyQBg _OKypEMHSEeStK8NH8ZPGbQ\".split(\" \")};")
        let enums: [(String, [String])] = [
            ("MajorState", ["DELETE_CLIP", "FORMAT", "IDLE", "PLAYBACK", "PRERECORD", "REC", "SHUTDOWN", "STBY", "UPDATE"]),
            ("GuiMode", ["NORMAL", "OVERLAY_MENU", "PLAYBACK", "ERASE"]),
            ("ExposureIndex", [160, 200, 250, 320, 400, 500, 640, 800, 1000, 1280, 1600, 2000, 2560, 3200].map { "EI_\($0)" }),
            ("NDFilter", ["CLEAR", "ZERO_POINT_SIX", "ONE_POINT_TWO", "TWO_POINT_ONE"]),
            ("ProjectRate", ["PR_23976", "PR_24", "PR_25", "PR_2997", "PR_30", "PR_48", "PR_50", "PR_5994", "PR_60"]),
            ("SensorFormat", ["HD", "S_3_2K", "S_4_3_2_8K"]),
            ("CodecType", ["PRORES_4444", "PRORES_4444_XQ", "ARRIRAW"]),
            ("LensSqueeze", ["S_1_0", "S_1_3", "S_2_0"]),
            ("ImageFlip", ["OFF", "V_FLIP", "H_FLOP", "VH_FLIPFLOP"]),
            ("IrisFullStops", ["INVALID", "T_07", "T_10", "T_14", "T_20", "T_28", "T_40", "T_56", "T_80", "T_110",
                               "T_160", "T_220", "T_320", "T_450", "T_640", "T_900", "T_1280", "T_1800", "T_2560",
                               "NEAR_CLOSE", "CLOSED"]),
            ("BatCapacityState", ["NotPresent", "NoCapacity", "CapacityValid"]),
            ("CardStatus", ["NONE", "INVALID", "EOL", "UNFORMATTED", "READY", "FULL", "ERROR", "SLOW", "DELETING",
                            "ERASING", "INIT", "COLD", "RECOVERY", "X"]),
            ("Character", (65...90).map { String(UnicodeScalar(UInt8($0))) }),
            ("PathProcessing", ["LOG", "LOOK", "A709"]),
            ("ExposureTool", ["ZEBRA", "FALSE_COLOR"]),
            ("SDIProcessing", ["CLEAN", "PROCESSED"]),
        ]
        lines.append("var e={" + enums.map { "\($0.0):[" + $0.1.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
            .joined(separator: ",") + "};")
        lines.append("var a={en:{}};")
        let labels: [String: [String]] = [
            "ExposureIndex": ["160", "200", "250", "320", "400", "500", "640", "800", "1000", "1280", "1600", "2000",
                              "2560", "3200"],
            "NDFilter": ["ND  -", "ND 0.6", "ND 1.2", "ND 2.1"],
            "ProjectRate": ["23.976p", "24p", "25p", "29.97p", "30p", "48p", "50p", "59.94p", "60p"],
            "SensorFormat": ["HD", "3.2K", "4:3 2.8K"], "CodecType": ["ProRes 4444", "ProRes 4444 XQ", "ARRIRAW"],
            "LensSqueeze": ["1.0", "1.3", "2.0"], "ImageFlip": ["Off", "V", "H", "V+H"],
            "IrisFullStops": ["-", "T 0.7", "T 1.0", "T 1.4", "T 2.0", "T 2.8", "T 4.0", "T 5.6", "T 8.0", "T 11",
                              "T 16", "T 22", "T 32", "T 45", "T 64", "T 90", "T 128", "T 180", "T 256", "near close",
                              "closed"],
            "PathProcessing": ["Log C", "Look", "ALEXA Classic 709"], "ExposureTool": ["Zebra", "False Color"],
            "MajorState": ["DELETE", "ERASE", "IDLE", "PLAY", "PREREC", "REC", "SHUTDOWN", "STBY", "UPDATE"],
            "GuiMode": ["NORMAL", "OVERLAY", "PLAY", "ERASE"],
            "SDIProcessing": ["Clean", "Processed"],
        ]
        let tokens = Dictionary(uniqueKeysWithValues: enums)
        for (type, list) in labels {
            for (token, label) in zip(tokens[type]!, list) { lines.append("a.en.ENUM_\(type)_\(token)=\"\(label)\";") }
        }
        return lines.joined(separator: "\n")
    }()

    static func reading(_ change: (inout [String: [String: Any]]) -> Void = { _ in }) throws -> ArriReading {
        var v = variables()
        change(&v)
        return ArriReading(snapshot: try ArriSnapshot(json: ["id": 3, "variables": v, "commands": [:]]),
                           catalog: ArriEnumCatalog(javascript: script))
    }
}

@Test func alexaMiniNamesResolve() throws {
    let r = try Mini.reading()
    #expect(r.fields[.recState] == "MajorState", "not RecordingIsPossible, a can-it-record flag")
    #expect(r.fields[.timecode] == nil, "the …StatusTimecodeIsOn overlay switches aren't the timecode")
    #expect(r.fields[.lensIris] == nil, "ButtonLensIrisShallLock is a button lock")
    #expect(r.fields[.lensFocus] == nil)
    #expect(r.fields[.colorBars] == "SDI1TestImageIsActive", "what its Color bars menu item and COLOR_BAR button switch")
    #expect(r.fields[.sensorMode] == "SensorFormat")
    #expect(r.fields[.codec] == "RecCodecType")
    #expect(r.fields[.desqueeze] == "LensSqueezeFactor")
    #expect(r.modelText == "ALEXA Mini")
    #expect(r.firmwareText == "SUP 6.1.2")
}

@Test func alexaMiniReadsAsTheCameraShowsIt() throws {
    var state = CameraState()
    try Mini.reading().apply(to: &state, host: "192.0.2.77")
    #expect(state.model == "ALEXA Mini")
    #expect(state.recording.state == .idle)
    let frames: Int = (15 * 60 + 32) * 24
    #expect(state.timecode?.frames == frames, "00:15:32:00 at 24p")
    #expect(state.timecode?.isRunning == true, "free run: the clock counts frames between the camera's seconds")
    #expect(state.iso?.value == 800)
    #expect(state.nd?.preset.options == ["Clear", "0.6", "1.2", "2.1"])
    #expect(state.frameRate?.project.options == ["8", "12", "23.976", "24", "25", "29.97", "30", "40", "48", "50"],
            "the camera's own list, inside its range")
    let angles: [Double] = [45, 90, 144, 172.8, 180, 270]
    #expect(state.shutterAngle?.options == angles)
    #expect(state.resolution?.value == "4:3 2.8K")
    #expect(state.resolution?.isWritable == true)
    #expect(state.resolution?.restartRequired == ["HD", "3.2K"], "every other format asks first: the camera reloads")
    #expect(state.fileFormat?.value == "ProRes 4444 XQ")
    #expect(state.fileFormat?.restartRequired == ["ARRIRAW"], "ProRes to ProRes doesn't reload; ProRes to ARRIRAW does")
    #expect(state.shutterAngle?.isWritable == true)
    #expect(state.lut?.value == "FilmUnlimited_500Tv2", "slot 1 of Look1…3_Filename, without .aml")
    #expect(state.desqueeze?.value == "1.0")
    #expect(state.colorBars == Choice(false, options: [false, true], isWritable: true))
    #expect(state.imageFlip == Choice(false, options: [false, true], isWritable: true))
    #expect(state.iris == nil, "no lens data")
    #expect(state.batteryPercent == nil, "no capacity reported")
    #expect(state.batteryVolts == 14.848, "Bat2, the supply, as the camera's display shows it")
    #expect(state.mediaRemainingMinutes == nil, "no card")
}

@Test func alexaMiniOutputs() throws {
    let r = try Mini.reading()
    #expect(r.outputs.map(\.name) == ["SDI 1", "SDI 2", "EVF", "MON"])
    let sdi1 = try #require(r.outputs.first { $0.id == "Sdi1" })
    #expect(sdi1.switches[.lut] == ArriSwitch(variable: "SDI1PathProcessing", on: .number(1), off: .number(0)))
    #expect(sdi1.switches[.frameGuides]?.variable == "SDIFramelinesAreOn", "shared by both SDI outputs")
    #expect(sdi1.switches[.focusAssist]?.variable == "SDIPeakingIsOn", "not the peaking mode")
    let evf = try #require(r.outputs.first { $0.id == "Evf" })
    #expect(evf.switches[.lut]?.variable == "EVFMonitorPathProcessing", "not the read-only …Effective")
    let mon = try #require(r.outputs.first { $0.id == "Mon" })
    #expect(mon.switches[.statusText]?.variable == "MonitorStatusInfo1IsOn", "not …OverlaysAreHidden")
    #expect(!r.outputs.flatMap(\.switches.values).contains { $0.variable.hasPrefix("Message") })
    // SDI 1/2 image is each SDI's clean feed: Clean on, Processed off.
    #expect(sdi1.switches[.cleanFeed] == ArriSwitch(variable: "SDI1Processing", on: .number(0), off: .number(1)))
    #expect(r.outputs.first { $0.id == "Sdi2" }?.switches[.cleanFeed]?.variable == "SDI2Processing")
    #expect(evf.switches[.cleanFeed] == nil && mon.switches[.cleanFeed] == nil, "no clean feed but on SDI")
    var state = CameraState()
    r.apply(to: &state, host: "192.0.2.77")
    let sdi1Out = try #require(state.monitoring?.outputs.first { $0.id == "Sdi1" })
    let sdi2Out = try #require(state.monitoring?.outputs.first { $0.id == "Sdi2" })
    #expect(sdi1Out.overlays[.cleanFeed] == Choice(false, options: [false, true], isWritable: true))
    #expect(sdi2Out.overlays[.cleanFeed]?.value == true)
    #expect(sdi2Out.overlays[.cleanFeed]?.isWritable == false, "SDI 1 processed: SDI 2 can't be processed too")
}

@Test func alexaMiniLensCardAndBattery() throws {
    var state = CameraState()
    try Mini.reading { v in
        v["LDSIrisFullStops"]?["value"] = 5          // T 2.8
        v["LDSIrisSubStops"]?["value"] = 5           // and 5/10 of a stop
        v["CardAStatus"]?["value"] = 4               // Ready
        v["CardACapacityRemain_Raw"]?["value"] = 450 // seconds
        v["Bat1CapacityState"]?["value"] = 2         // CapacityValid
        v["Bat1LevelPercent"]?["value"] = 64
    }.apply(to: &state, host: "192.0.2.77")
    #expect(state.iris?.value == 3.3)
    #expect(state.mediaRemainingMinutes == 7, "450 s, not 450 minutes")
    #expect(state.batteryPercent == 64)
}

@Test func alexaMiniLocksRateAndShutterWhileRolling() throws {
    // Rolling, the Mini takes a shutter or sensor-rate write and ignores it, with nothing marked read-only.
    var state = CameraState()
    try Mini.reading { $0["MajorState"]?["value"] = 5 }.apply(to: &state, host: "192.0.2.77")
    #expect(state.recording.state == .recording)
    #expect(state.shutterAngle?.isWritable == false)
    #expect(state.frameRate?.project.isWritable == false)
    #expect(state.iso?.isWritable == true, "EI, ND and white balance still change mid-take")
}

@Test func aSwitchTheCameraOffersOneWayIsNotOffered() throws {
    // SDI 2 clean: its path processing offers only Look (properties [1, 3, 1]), so the look switch can't go off.
    var state = CameraState()
    try Mini.reading().apply(to: &state, host: "192.0.2.77")
    let sdi2 = try #require(state.monitoring?.outputs.first { $0.id == "Sdi2" })
    #expect(sdi2.overlays[.lut]?.isWritable == false)
    let sdi1 = try #require(state.monitoring?.outputs.first { $0.id == "Sdi1" })
    #expect(sdi1.overlays[.lut]?.isWritable == true)
}

@Test func alexaMiniStuckOnItsPlaybackPageReadsAsReview() throws {
    // A Mini in standby with nothing cued whose screen is still on its playback page (GuiMode PLAYBACK),
    // saying "No clip selected": from the 2026-10-29 capture, snapshot 012. Shown as review, so Live is there to
    // clear it and Play cues the last take.
    func playback(major: Int, gui: Int, clip: Int) throws -> PlaybackState? {
        var state = CameraState()
        try Mini.reading {
            $0["MajorState"]?["value"] = major
            $0["GuiMode"]?["value"] = gui
            $0["PlaybackClipIndex"] = ["value": clip, "type": "int", "readonly": 1]
            $0["ClipCountCardB"] = ["value": 50, "type": "int", "readonly": 1]
        }.apply(to: &state, host: "192.0.2.77")
        return state.playback
    }
    let r = try Mini.reading()
    #expect(r.catalog.tokens(forVariable: "GuiMode") == ["NORMAL", "OVERLAY_MENU", "PLAYBACK", "ERASE"],
            "the enum's tokens, not the page's dependency list keyed by the same name")
    #expect(try playback(major: 7, gui: 2, clip: -1)?.inReview == true, "standby, its screen on the playback page")
    #expect(try playback(major: 3, gui: 2, clip: 50)?.inReview == true, "playing back")
    #expect(try playback(major: 3, gui: 0, clip: -1)?.inReview == true, "MajorState PLAYBACK alone")
    #expect(try playback(major: 7, gui: 0, clip: -1)?.inReview == false, "live")
    #expect(try playback(major: 7, gui: 1, clip: -1)?.inReview == false, "a menu open on the camera isn't review")
    #expect(try playback(major: 5, gui: 2, clip: -1)?.inReview == false, "rolling: never review, so no Live to a take")
}

@Test func alexaMiniColourBarsAndImageFlip() throws {
    func state(_ change: @escaping (inout [String: [String: Any]]) -> Void) throws -> CameraState {
        var state = CameraState()
        try Mini.reading(change).apply(to: &state, host: "192.0.2.77")
        return state
    }
    // Color bars: SDI1TestImageIsActive, in standby only.
    #expect(try state { $0["SDI1TestImageIsActive"]?["value"] = true }.colorBars?.value == true)
    #expect(try state { $0["MajorState"]?["value"] = 5 }.colorBars?.isWritable == false, "rolling: no bars")
    // Image flip: Off, V, H or V+H; any flip reads on, and on is V+H (the camera upside down).
    #expect(try state { $0["SensorImageFlip"]?["value"] = 3 }.imageFlip?.value == true)
    #expect(try state { $0["SensorImageFlip"]?["value"] = 1 }.imageFlip?.value == true, "V alone is a flip too")
    #expect(try state { $0["MajorState"]?["value"] = 5 }.imageFlip?.isWritable == false, "rolling: no flip mid-take")
    let r = try Mini.reading()
    #expect(r.switchBinding(.imageFlip, onWords: ArriReading.flipWords)
            == ArriSwitch(variable: "SensorImageFlip", on: .number(3), off: .number(0)))
}

@Test func aFlipWithAMirrorChoiceStillTurnsOnUpsideDown() throws {
    // A body whose choices read "Off, Flip H, Flip V, Flip V+H", or "Horizontal": "on" is still both ways.
    let script = """
        var c={};c.SensorImageFlip={name:"SensorImageFlip",value:"X",type:"Flip"};
        var e={Flip:["OFF","H","V","VH"]};var a={en:{}};
        a.en.ENUM_Flip_OFF="Off";a.en.ENUM_Flip_H="Horizontal";a.en.ENUM_Flip_V="Flip V";a.en.ENUM_Flip_VH="Flip V+H";
        """
    let flip: [String: Any] = ["value": 0, "type": "enumint", "min": 0, "max": 3, "properties": [3, 3, 3, 3], "readonly": 0]
    let r = ArriReading(snapshot: try ArriSnapshot(json: ["id": 1, "variables": ["SensorImageFlip": flip], "commands": [:]]),
                        catalog: ArriEnumCatalog(javascript: script))
    #expect(r.switchBinding(.imageFlip, onWords: ArriReading.flipWords)?.on == .number(3))
}

@Test func sdi2ClonesSDI1WhenFlagIsOn() throws {
    // With SDI2IsSDI1Clone on, Sdi2 follows Sdi1, its overlays show SDI 1's values and aren't writable, and
    // sameAsSwitch reports on and writable so the user can turn the clone off.
    var cloneOn = CameraState()
    try Mini.reading { $0["SDI2IsSDI1Clone"]?["value"] = true }
        .apply(to: &cloneOn, host: "192.0.2.77")
    let sdi2 = try #require(cloneOn.monitoring?.outputs.first { $0.id == "Sdi2" })
    let sdi1 = try #require(cloneOn.monitoring?.outputs.first { $0.id == "Sdi1" })
    #expect(sdi2.follows == "Sdi1", "clone on: Sdi2 follows Sdi1")
    // Clean feed on Sdi2 reflects Sdi1's value and is not writable while cloning.
    #expect(sdi2.overlays[.cleanFeed]?.value == sdi1.overlays[.cleanFeed]?.value)
    #expect(sdi2.overlays[.cleanFeed]?.isWritable == false)
    // sameAsSwitch is on and writable.
    let sw = try #require(sdi2.sameAsSwitch)
    #expect(sw.value == true)
    #expect(sw.isWritable == true)

    // With the clone off, Sdi2 is independent and sameAsSwitch is off.
    var cloneOff = CameraState()
    try Mini.reading().apply(to: &cloneOff, host: "192.0.2.77")
    let sdi2Off = try #require(cloneOff.monitoring?.outputs.first { $0.id == "Sdi2" })
    #expect(sdi2Off.follows == nil, "clone off: no follows")
    let swOff = try #require(sdi2Off.sameAsSwitch)
    #expect(swOff.value == false)
}

@Test func alexaMiniVoltsAsItsDisplayShowsThem() throws {
    func volts(bat1: Double, bat2: Double) throws -> Double? {
        var state = CameraState()
        try Mini.reading {
            $0["Bat1LevelVolt"]?["value"] = bat1
            $0["Bat2LevelVolt"]?["value"] = bat2
        }.apply(to: &state, host: "192.0.2.77")
        return state.batteryVolts
    }
    #expect(try volts(bat1: 0, bat2: 14.848) == 14.848)
    #expect(try volts(bat1: 16.2, bat2: 14.8) == 16.2, "Bat1 at least 1 V higher: the camera shows Bat1")
    #expect(try volts(bat1: 15.3, bat2: 14.8) == 14.8, "less than 1 V higher: still Bat2")
    #expect(try volts(bat1: 0, bat2: 0) == nil, "nothing there")
}

/// A Mini's reel is read from its card's variable (ReelCountCardA/B); writing to the generic one (ClipNameReelCount),
/// which a Mini doesn't have, is the wrong path. Both go through `reelField`.
@Test func alexaMiniReelIsTheCardsBothWays() throws {
    #expect(try Mini.reading().reelField == .reelCardA, "no card: the per-card variable it has")
    #expect(try Mini.reading { $0["CardAStatus"]?["value"] = 4 }.reelField == .reelCardA, "card A in")
}
