import Foundation

extension MockCameraBackend {
    /// A camera's letter as its clip names' camera ID (VENICE, ARRI): its first letter, A to Z, else A.
    static func cameraID(_ label: String) -> String {
        guard let first = label.uppercased().unicodeScalars.first, (65...90).contains(first.value) else { return "A" }
        return String(first)
    }

    /// A VENICE 2 as Tiles reads the real one (MPC-3628, FW V4.00), for Test Mode and edit mode's
    /// stand-in: 8-step ND, EI with a High base, 5.6°–360° shutter, 2000–15000 K with tint, Select FPS, no live view
    /// (the Web Remote has none), the look's presets and user 3D LUTs, false color on the Monitor out and the
    /// viewfinder, HDMI showing the same as the Monitor, clip naming, the battery in volts, media as recordable time.
    /// `label`: the camera's letter, its clip names' camera ID, so two demo VENICEs on a page read B005C003 beside A005C003.
    public static func veniceSampleState(label: String = "A", now: Date = Date()) -> CameraState {
        var s = CameraState()
        s.connection = .connected
        s.make = .sony
        s.model = "MPC-3628"
        s.recording = RecordingControl(state: .idle)
        s.timecode = TimecodeClock(frames: 5 * 3600 * 24, anchor: now, rate: 24, fps: 24, isRunning: false)
        s.timecodeShowsDuration = Choice(false, options: [false, true])
        s.iso = Choice(800, options: VeniceTables.eiOptions(base: 800))
        // VENICE 2's dual base: 800 and 3200 (VENICE 1's is 500/2500). Switching base moves the EI list, like the
        // other Sony demos.
        s.baseISO = Choice(800, options: [800, 3200])
        s.shutterMode = Choice(.angle, options: [.angle, .speed])
        s.shutterAngle = Choice(180, options: VeniceTables.shutterAngles)
        s.shutterSpeed = Choice("1/48", options: VeniceTables.shutterSpeeds(projectRate: "24"))
        s.nd = NDState(preset: Choice("0.6", options: ["Clear", "0.3", "0.6", "0.9", "1.2", "1.5", "1.8", "2.1", "2.4"]))
        s.whiteBalance = WhiteBalanceState(
            preset: Choice("5500K", options: WhiteBalancePresets.labels(within: 2000...15000)
                           + VeniceTables.whiteBalanceSteps.filter { !WhiteBalancePresets.labels(within: 2000...15000).contains($0) }),
            kelvin: Level(5500, range: 2000...15000, step: 10),
            tint: Level(0, range: -99...99, step: 1))
        // Imager mode, format, project rate and de-squeeze restart the camera's image: their tiles ask first.
        func restarting(_ value: String, _ options: [String]) -> Choice<String> {
            Choice(value, options: options, restartRequired: Set(options.filter { $0 != value }))
        }
        s.frameRate = FrameRateState(
            project: restarting("24", VeniceTables.projectFrameRates(imager: "8.6K 3:2")),
            variable: Choice(false, options: [false, true]),
            variableRate: Choice(24, options: VeniceTables.selectFPS(imager: "8.6K 3:2", projectRate: "24")),
            variableName: "Select FPS")
        s.resolution = restarting("8.6K 3:2", VeniceTables.imagerModes(model: "MPC-3628"))
        s.fileFormat = restarting("X-OCN LT", VeniceTables.recordingFormats(imager: "8.6K 3:2", projectRate: "24"))
        s.desqueeze = restarting("Off", VeniceDesqueeze.options(forImager: "8.6K 3:2"))
        s.iris = Choice(2.8, options: [1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0,
                                       9.0, 10, 11, 13, 14, 16, 18, 20, 22])
        // VENICE 2's outputs as it reports them: a LUT, frame lines and the info overlay on each, HDMI too (its "hdmi"
        // LUT entry); false color on the Monitor out and the viewfinder (the Exposure Assist buttons), and peaking (one
        // switch for both); zebra on the viewfinder. HDMI shows the same as the Monitor, as the real one did
        // (OutputFormat.Info.Hdmi "2").
        func output(_ id: String, _ name: String, has: [MonitorOverlay], on: Set<MonitorOverlay>,
                    follows: String? = nil) -> MonitorOutput {
            MonitorOutput(id: id, name: name, overlays: Dictionary(uniqueKeysWithValues: has.map {
                ($0, Choice(on.contains($0), options: [false, true], isWritable: follows == nil || $0 == .lut))
            }), follows: follows)
        }
        s.monitoring = MonitoringState(outputs: [
            output("Sdi12", "SDI 1/2", has: [.lut, .frameGuides, .statusText], on: [.lut, .frameGuides]),
            output("Sdi34", "SDI 3/4", has: [.lut, .frameGuides, .statusText], on: [.lut, .frameGuides]),
            output("Monitor", "Monitor", has: [.lut, .frameGuides, .statusText, .falseColor, .focusAssist],
                   on: [.lut, .frameGuides, .statusText]),
            output("Vf", "VF", has: [.lut, .frameGuides, .statusText, .falseColor, .zebra, .focusAssist],
                   on: [.lut, .frameGuides, .statusText]),
            output("Hdmi", "HDMI", has: [.lut, .frameGuides, .statusText], on: [.lut, .frameGuides, .statusText],
                   follows: "Monitor"),
        ])
        s.look = s.monitoring?.onEverywhere(.lut)
        // The look every output with a LUT on shows: the presets, then the user 3D LUTs loaded on the camera.
        s.lut = Choice("User 1: TW Show LUT.cube",
                       options: ["s709", "R709(800%)", "S-Gamut3.Cine/SLog3", "S-Gamut3/SLog3", "User 1: TW Show LUT.cube",
                                 "User 2: TW Night.cube", "User 3: GK_SLOG3_Rec709_FC.cube"])
        s.offersFalseColorLUTSwap = false
        s.falseColor = s.monitoring?.onEverywhere(.falseColor)
        var naming = FileNaming(cameraID: Choice(Self.cameraID(label), options: (65...90).map { String(UnicodeScalar(UInt8($0))) }),
                                reel: Level(5, range: 1...999, step: 1))
        naming.position = Choice("C", options: ["C", "L", "R"])
        s.fileNaming = naming
        s.clipName = "\(Self.cameraID(label))005C003"
        s.colorBars = Choice(false, options: [false, true])
        s.imageFlip = Choice(false, options: [false, true])
        s.webRemoteURL = URL(string: "http://venice.local/rm.html")
        s.playback = PlaybackState(isPlaying: false, inReview: false, clipName: "\(Self.cameraID(label))005C002", clipNumber: 2, clipCount: 3,
                                   capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true,
                                                                      seek: false, fastForwardRewind: true,
                                                                      recReview: false, live: false, review: true,
                                                                      scanSpeed: 4))
        // VENICE 2 shows its battery in volts (it reads no percentage while it does).
        s.batteryVolts = 14.6
        s.mediaRemainingMinutes = 46
        s.latencyMilliseconds = 6
        // Its menu keys, its frame line sets' user frame lines (both off, as the real one read) and four audio meters.
        s.cameraButtons = [.menu, .home, .back, .up, .down, .enter]
        s.userFrameLinesA = Choice(UserFrameLines.off, options: UserFrameLines.options)
        s.userFrameLinesB = Choice(UserFrameLines.off, options: UserFrameLines.options)
        s.audioMeterCount = 4
        s.audioMeters = [0.62, 0.58, 0.17, 0.17]
        return s
    }
}

extension DashboardStore {
    /// A VENICE for Test Mode and edit mode, like `previewState(_:lastSeen:)`'s PYXIS branch.
    static func isVenice(_ saved: SavedCamera, lastSeen: CameraProfile?) -> Bool {
        if saved.connection.venice != nil { return true }
        guard let model = lastSeen?.model?.uppercased() else { return false }
        return model.contains("VENICE") || model == "MPC-3610" || model == "MPC-3628"
    }
}

/// VENICE 2's de-squeeze ratios by imager mode and recording format, from Sony's VENICE 2 manual (MPC-3628 / MPC-3626,
/// FW 2.0, Project > Anamo. De-Squeeze, p. 59–60). Anything but Off needs the Anamorphic License. The ratio is part of
/// Project > Imager Mode. An early VENICE 2 manual prints 1.65× where FW 2.0's prints 1.6×; the camera's own list wins
/// whenever it gives one (`Capability.GetValue`).
public enum VeniceDesqueeze {
    /// Every ratio, in the camera's order.
    public static let all = ["Off", "1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"]

    /// The ratios an imager mode allows, by its name as the camera shows it ("8.6K 3:2", "4K 4:3 Surround View"). With
    /// X-OCN the aspect decides, the same on both sensors. ProRes has its own table (some modes have no Off: the
    /// ProRes image is the de-squeezed one).
    public static func options(forImager imager: String, model: String? = nil, codec: String? = nil) -> [String] {
        if VeniceTables.isProRes(codec), let mode = VeniceTables.mode(imager, model: model),
           let list = (VeniceTables.isSixK(model) ? proRes6K : proRes86K)[mode] {
            return list
        }
        switch VeniceTables.aspect(imager) {
        case "3:2": return all
        case "17:9": return ["Off", "1.25x", "1.3x", "1.6x", "1.8x", "2.0x"]
        case "4:3": return ["Off", "1.3x", "1.6x", "1.8x", "2.0x"]
        case "6:5": return ["Off", "2.0x"]
        case "2.39:1", "16:9", "1.85:1": return ["Off"]
        default: return all
        }
    }

    // ProRes (p. 59–60). 1.25× only for 4K ProRes (Zoom to Fit 17:9).
    static let proRes86K: [String: [String]] = [
        "8.6k 3:2": ["1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"], "8.6k 17:9": ["Off"], "8.2k 17:9": ["Off"],
        "8.2k 2.39:1": ["Off"], "8.1k 16:9": ["Off"], "7.6k 16:9": ["Off"], "5.8k 6:5": ["2.0x"],
        "5.8k 4:3": ["1.3x", "1.6x", "1.8x", "2.0x"], "5.8k 17:9": ["Off"], "5.5k 2.39:1": ["Off"], "5.4k 16:9": ["Off"],
    ]
    static let proRes6K: [String: [String]] = [
        "6k 3:2": ["1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"], "6k 1.85:1": [], "6k 17:9": ["Off"],
        "6k 2.39:1": ["Off"], "5.7k 16:9": ["Off"], "4k 6:5": ["2.0x"], "4k 4:3 surround": [],
        "4k 4:3": ["1.3x", "1.6x", "1.8x", "2.0x"], "4k 17:9 surround": ["Off"], "4k 17:9": ["Off"],
        "4k 2.39:1": ["Off"], "3.8k 16:9 surround": ["Off"], "3.8k 16:9": ["Off"],
    ]
}

/// VENICE 2 option lists from Sony's VENICE 2 manual (MPC-3628 / MPC-3626, FW 2.0: the Home screen of the sub display,
/// p. 49–51; the Shooting and Project menus, p. 58–73; the license and recording-format tables, p. 5–6 and 64–70) and
/// Sony's V3.00 release notes (33.33 FPS, Log(Legal)), for Test Mode and for when a camera doesn't list its own. The
/// camera's own lists win (`Capability.GetValue`): its step lists are user-editable (Step Edit), so they can differ per
/// camera, and newer firmware can add to them. MPC-3628 is the 8.6K full-frame sensor, MPC-3626 the 6K (VENICE 1's
/// sensor); VENICE 1 (MPC-3610) itself isn't in this manual, so a VENICE 1 gets no imager-mode lists from here.
public enum VeniceTables {
    /// EI by base ISO (p. 50). MPC-3628 (8.6K): base 800 and 3200; MPC-3626 (6K): 500 and 2500.
    public static func eiOptions(base: Int) -> [Int] {
        switch base {
        case 3200: [800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
        case 500: [125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000]
        case 2500: [640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000]
        default: [200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]
        }
    }

    /// The camera's default shutter steps (up to 16, editable); continuous runs 4.2°–360° and 1/24–1/8000 (p. 72).
    public static let shutterAngles: [Double] = [5.6, 11.2, 22.5, 45, 90, 144, 172.8, 180, 360]
    /// Shooting > Shutter's default speed steps (p. 72; the sub display's page leaves out 1/48).
    public static let shutterSpeeds = ["1/24", "1/25", "1/30", "1/48", "1/50", "1/60", "1/100", "1/120", "1/250", "1/500",
                                       "1/1000", "1/2000"]

    /// The default speed steps at a project frame rate: none slower than a frame (p. 51, 72: "1/60 and subsequent
    /// values when the project frame rate is 59.94, 1/50 … when 50.0, 1/30 … when 29.97, and 1/25 … when 25.0";
    /// 47.95's default is 1/48).
    public static func shutterSpeeds(projectRate: String?) -> [String] {
        guard let fps = projectRate.flatMap({ Double($0) }), fps > 0 else { return shutterSpeeds }
        let slowest = (fps - 0.1).rounded(.up)  // 23.98 → 24, 29.97 → 30, 47.95 → 48, 59.94 → 60
        return shutterSpeeds.filter { label in
            guard let denominator = Double(label.dropFirst(2)) else { return true }
            return denominator >= slowest
        }
    }

    /// The LUTs the Monitor out and viewfinder offer with S-Gamut3(.Cine)/S-Log3 or ACEScct (p. 51), besides Log (off).
    public static let monitorLUTs = ["s709", "R709(800%)", "Look"]

    /// Whether an output's LUT setting means no LUT: Log, and FW 3.0's Log(Legal) (S-Log3 in legal range).
    public static func isLog(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("log")
    }

    /// The camera's default white balance steps (Temp + Tint 00; editable on the camera, p. 51). Temp runs
    /// 2000K–15000K and tint −99 to +99 (p. 129).
    public static let whiteBalanceSteps = ["3200K", "4300K", "5500K"]

    /// The imager modes, in the order of Sony's license tables (p. 5–6). The 8.6K modes need the Full-Frame License,
    /// 5.8K 6:5 / 4:3 (6K: 4K 6:5 / 4:3) the Anamorphic License; the camera lists only what it's licensed for.
    public static func imagerModes(model: String?) -> [String] {
        if isVenice1(model) { return [] }
        return isSixK(model) ? modes6K.map(\.name) : modes86K.map(\.name)
    }

    /// The 8.6K sensor's imager modes (backwards compatible name: MPC-3628's).
    public static let imagerModes = modes86K.map(\.name)

    /// Recording formats, as Project > Recording Format names them (p. 58–59).
    public static let recordingFormats = ["X-OCN XT", "X-OCN ST", "X-OCN LT", "ProRes 4444 XQ 4K", "ProRes 4444 XQ QFHD",
                                          "ProRes 4444 4K", "ProRes 4444 QFHD", "ProRes 422 HQ 4K", "ProRes 422 HQ QFHD"]

    /// The recording formats an imager mode and project frame rate allow (p. 64–70). Without a mode Tiles knows, every
    /// format.
    public static func recordingFormats(imager: String, model: String? = nil, projectRate: String? = nil) -> [String] {
        guard let row = row(imager, model: model) else { return recordingFormats }
        let rate = rateIndex(projectRate)
        func allowed(_ mask: String) -> Bool {
            guard let rate else { return mask.contains("1") }
            return Array(mask)[rate] == "1"
        }
        return recordingFormats.filter { format in
            switch format {
            case "X-OCN XT": return allowed(row.xt)
            case "X-OCN ST": return allowed(row.st)
            case "X-OCN LT": return allowed(row.lt)
            case let f where f.hasSuffix("QFHD"): return allowed(row.proResQFHD)
            default: return allowed(row.proRes4K)
            }
        }
    }

    /// Project frame rates an imager mode allows (p. 5–6). Every mode takes 23.98 to 29.97.
    public static func projectFrameRates(imager: String, model: String? = nil) -> [String] {
        guard let row = row(imager, model: model) else { return Array(rates.prefix(4)) }
        return zip(rates, Array(row.project)).filter { $0.1 == "1" }.map(\.0)
    }

    /// Select FPS rates (variable speed): 1 to the mode's top speed, plus its high-speed steps (p. 49–50). ProRes has
    /// its own limits (4444 XQ / 4444 to 60, 422 HQ higher). Rates of 7 or lower aren't allowed at the high base ISO
    /// (3200, or 2500 with ProRes). FW 3.0 adds 33.33 at project 24, 25 and 50 (Sony's V3.00 release notes).
    public static func selectFPS(imager: String, model: String? = nil, codec: String? = nil, highBase: Bool = false,
                                 projectRate: String? = nil) -> [Double] {
        let sixK = isSixK(model)
        let row = self.row(imager, model: model)
        var top = row?.xocnTop ?? 60
        var extra = row?.xocnExtra ?? []
        if isProRes(codec), let row {
            if let proRes = codec?.contains("422") == true ? row.proRes422 : row.proRes4444 {
                top = proRes.top
                extra = proRes.extra
            } else {
                top = min(top, 60)  // no ProRes row in Sony's table: no high-speed steps assumed
                extra = []
            }
        }
        let lowest = highBase && (!sixK || isProRes(codec)) ? 8 : 1
        var list = (Array(lowest...max(top, lowest)) + extra).map(Double.init)
        if let projectRate, ["24", "25", "50"].contains(projectRate), Double(top) > 33.33 { list.append(33.33) }
        return list.sorted()
    }

    // MARK: - The tables

    static let rates = ["23.98", "24", "25", "29.97", "47.95", "50", "59.94"]

    /// One imager mode: its project frame rates and recording formats as masks over `rates` (p. 5–6, 64–70), its top
    /// Select FPS with X-OCN and the high-speed steps above 60 (p. 49), and ProRes's (p. 50; nil where Sony's ProRes
    /// table has no row: X-OCN's top, capped at 60).
    struct Mode {
        var name: String
        var project: String
        var xt: String, st: String, lt: String
        var proRes4K: String, proResQFHD: String
        var xocnTop: Int
        var xocnExtra: [Int] = []
        var proRes4444: (top: Int, extra: [Int])? = nil
        var proRes422: (top: Int, extra: [Int])? = nil
    }

    static let hfr90 = [66, 72, 75, 88, 90]
    static let hfr110 = [66, 72, 75, 88, 90, 96, 100, 110]
    static let hfr120 = [66, 72, 75, 88, 90, 96, 100, 110, 120]

    /// MPC-3628, the 8.6K sensor.
    static let modes86K: [Mode] = [
        Mode(name: "8.6K 3:2", project: "1111000", xt: "1111000", st: "1111000", lt: "1111000", proRes4K: "1111000",
             proResQFHD: "1111000", xocnTop: 30, proRes4444: (30, []), proRes422: (30, [])),
        Mode(name: "8.6K 17:9", project: "1111100", xt: "1111000", st: "1111100", lt: "1111100", proRes4K: "1111000",
             proResQFHD: "0000000", xocnTop: 48, proRes4444: (48, []), proRes422: (48, [])),
        Mode(name: "8.2K 2.39:1", project: "1111111", xt: "1111110", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: [66, 72], proRes4444: (60, []), proRes422: (60, [66, 72])),
        Mode(name: "8.2K 17:9", project: "1111111", xt: "1111000", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, proRes4444: (60, []), proRes422: (60, [])),
        Mode(name: "8.1K 16:9", project: "1111000", xt: "1111000", st: "1111000", lt: "1111000", proRes4K: "0000000",
             proResQFHD: "1111000", xocnTop: 48, proRes4444: (48, []), proRes422: (48, [])),
        Mode(name: "7.6K 16:9", project: "1111011", xt: "1111000", st: "1111011", lt: "1111011", proRes4K: "0000000",
             proResQFHD: "1111011", xocnTop: 60, proRes4444: (60, []), proRes422: (60, [])),
        Mode(name: "5.8K 6:5", project: "1111100", xt: "1111100", st: "1111100", lt: "1111100", proRes4K: "1111000",
             proResQFHD: "1111000", xocnTop: 48, proRes4444: (48, []), proRes422: (48, [])),
        Mode(name: "5.8K 4:3", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "1111011", xocnTop: 60, proRes4444: (60, []), proRes422: (60, [])),
        Mode(name: "5.8K 17:9", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: hfr90, proRes4444: (60, []), proRes422: (60, [66, 72, 75])),
        Mode(name: "5.5K 2.39:1", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: hfr120, proRes4444: (60, []), proRes422: (60, [66, 72, 75])),
        Mode(name: "5.4K 16:9", project: "1111011", xt: "1111011", st: "1111011", lt: "1111011", proRes4K: "0000000",
             proResQFHD: "1111011", xocnTop: 60, xocnExtra: hfr90, proRes4444: (60, []), proRes422: (60, [66, 72, 75])),
    ]

    /// MPC-3626, the 6K sensor.
    static let modes6K: [Mode] = [
        Mode(name: "6K 3:2", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "1111011", xocnTop: 60),
        Mode(name: "6K 1.85:1", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "0000000",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: [66, 72]),
        Mode(name: "6K 17:9", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: [66, 72], proRes4444: (60, []), proRes422: (60, [66, 72])),
        Mode(name: "6K 2.39:1", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: hfr90, proRes4444: (60, []), proRes422: (60, [66, 72, 75])),
        Mode(name: "5.7K 16:9", project: "1111011", xt: "1111011", st: "1111011", lt: "1111011", proRes4K: "0000000",
             proResQFHD: "1111011", xocnTop: 60, xocnExtra: [66, 72], proRes4444: (60, []), proRes422: (60, [66, 72])),
        Mode(name: "4K 6:5", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "1111011", xocnTop: 60, xocnExtra: [66, 72], proRes4444: (60, []), proRes422: (60, [66, 72])),
        Mode(name: "4K 4:3", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "1111011", xocnTop: 60, xocnExtra: [66, 72, 75]),
        Mode(name: "4K 4:3 Surround View", project: "1111000", xt: "1111000", st: "1111000", lt: "1111000",
             proRes4K: "0000000", proResQFHD: "0000000", xocnTop: 30),
        Mode(name: "4K 17:9", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: hfr110, proRes4444: (60, []), proRes422: (60, hfr90)),
        Mode(name: "4K 17:9 Surround View", project: "1111000", xt: "1111000", st: "1111000", lt: "1111000",
             proRes4K: "1111000", proResQFHD: "0000000", xocnTop: 48, proRes4444: (48, []), proRes422: (48, [])),
        Mode(name: "4K 2.39:1", project: "1111111", xt: "1111111", st: "1111111", lt: "1111111", proRes4K: "1111011",
             proResQFHD: "0000000", xocnTop: 60, xocnExtra: hfr120, proRes4444: (60, []), proRes422: (60, hfr90)),
        Mode(name: "3.8K 16:9", project: "1111011", xt: "1111011", st: "1111011", lt: "1111011", proRes4K: "0000000",
             proResQFHD: "1111011", xocnTop: 60, xocnExtra: hfr110, proRes4444: (60, []), proRes422: (60, hfr90)),
        Mode(name: "3.8K 16:9 Surround View", project: "1111000", xt: "1111000", st: "1111000", lt: "1111000",
             proRes4K: "0000000", proResQFHD: "1111000", xocnTop: 48, proRes4444: (48, []), proRes422: (48, [])),
    ]

    // MARK: - Reading the camera's names

    /// MPC-3626: the 6K sensor (base ISO 500 / 2500). Everything else this file has is the 8.6K's.
    static func isSixK(_ model: String?) -> Bool { model?.contains("3626") == true }
    /// VENICE 1 (MPC-3610), which this manual doesn't cover.
    static func isVenice1(_ model: String?) -> Bool { model?.contains("3610") == true }

    static func isProRes(_ codec: String?) -> Bool { codec?.localizedCaseInsensitiveContains("ProRes") == true }

    /// An imager mode's key in these tables: lower case, "Surround View" as "surround", sensor prefixes ("FF", "S35")
    /// and spaces tidied. Nil for a mode this sensor's tables don't have.
    static func mode(_ imager: String, model: String?) -> String? {
        let key = normalised(imager)
        let table = isSixK(model) ? modes6K : modes86K
        return table.contains { normalised($0.name) == key } ? key : nil
    }

    static func row(_ imager: String, model: String?) -> Mode? {
        guard !isVenice1(model) else { return nil }
        let key = normalised(imager)
        return (isSixK(model) ? modes6K : modes86K).first { normalised($0.name) == key }
    }

    public static func normalised(_ imager: String) -> String {
        var words = imager.lowercased().replacingOccurrences(of: "×", with: "x")
            .split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
        words.removeAll { $0 == "view" || $0 == "ff" || $0 == "s35" || $0 == "full-frame" }
        return words.joined(separator: " ")
    }

    /// The aspect ratio in an imager mode's name ("3:2", "2.39:1", "17:9"), wherever it sits.
    static func aspect(_ imager: String) -> String {
        guard let range = imager.range(of: #"\d+(\.\d+)?:\d+"#, options: .regularExpression) else { return "" }
        return String(imager[range])
    }

    static func rateIndex(_ projectRate: String?) -> Int? {
        guard let projectRate, let fps = Double(projectRate) else { return nil }
        return rates.firstIndex { abs((Double($0) ?? 0) - fps) < 0.05 }
    }
}
