import CameraCore
import Foundation
import os

extension VeniceCameraBackend {
    // MARK: - Value helpers

    static let ndLabels = ["Clear", "0.3", "0.6", "0.9", "1.2", "1.5", "1.8", "2.1", "2.4"]
    static let flipImage = "P.System.Menu.FlipImage"
    static let batteryVolts = "System.Battery.Active.Remain.Voltage"
    // VENICE 2's Clip Naming and TC/Media menus (WebMenu.js, savona-2.9.4).
    static let clipCameraID = "P.System.Menu.ClipnamingCameraid"        // "66" = B (ASCII)
    static let clipReel = "P.System.Menu.ClipnamingReelNum"             // "20" = reel 020
    static let clipPosition = "P.System.Menu.ClipnamingCameraposition"  // "0" C, "1" L, "2" R
    static let timeDataDisplay = "P.System.Menu.TimecodeDispTc"         // "3" Timecode, "2" Duration
    static let mediaboxStatus = "P.Clip.Mediabox.Status"
    static let mediaboxSpeed = "P.Clip.Mediabox.Speed"
    /// {"selectClip": true} once a clip in playback can play.
    static let playbackEnabled = "Clip.Mediabox.PlaybackEnabled"
    static let colorBarEnabled = "Camera.ColorBar.Enabled"
    /// The Camera Menu's keys (`Button.SendKeys`). Set, UpArrow, DownArrow and Home are the camera page's own
    /// (KeyConverter.js); Menu ("Open/Close camera menu") and Cancel ("the Cancel/Back button") are SkaarHoj's, from its
    /// VENICE 2 core's manual. None of the menu ones has been pressed on a camera yet.
    static let menuKeys: [CameraBodyButton: String] = [
        .menu: "Menu", .home: "Home", .back: "Cancel", .up: "UpArrow", .down: "DownArrow", .enter: "Set",
    ]
    /// User Frame Line 1 and 2 in frame line set A, and in B (WebMenu.js: L4_USER_FRAME_LINE_CHECK_BOX_A…), "0" / "1".
    static let userFrameA = (first: "P.System.Menu.MarkerAUserBoxOnoff", second: "P.System.Menu.MarkerAUserBox2Onoff")
    /// Which frame line set each output shows, by Tiles' output id: "0" Line A, "1" Line B (VENICE 2's menu; the
    /// 2026-10-23 camera had SDI 1/2 on Line B).
    static let frameLineSelect = ["Sdi12": "P.System.Menu.MarkerSdi12Select", "Sdi34": "P.System.Menu.MarkerSdi34Select",
                                  "Monitor": "P.System.Menu.MarkerMonitorSelect", "Vf": "P.System.Menu.MarkerVfSelect",
                                  "Hdmi": "P.System.Menu.MarkerHdmiSelect"]
    /// Which info set each output's overlay shows: "0" Info A, "1" Info B, "2" the REC indicator only. One for SDI 1/2
    /// and 3/4, as the overlay switch.
    static let infoSetSelect = ["Sdi12": "P.System.Menu.SdiOsdDisplayInfoSelect", "Sdi34": "P.System.Menu.SdiOsdDisplayInfoSelect",
                                "Monitor": "P.System.Menu.MonitorOsdDisplayInfoSelect", "Vf": "P.System.Menu.VfOsdDisplayInfoSelect",
                                "Hdmi": "P.System.Menu.HdmiOsdDisplayInfoSelect"]
    /// The audio level meter in each info set, by the set's select value: an output's audio meters are its set's, so
    /// they show or hide on every output showing that set.
    static let audioMeterInInfoSet = ["0": "P.System.Menu.DisplayInfoAAudioLevelMeterOnoff",
                                      "1": "P.System.Menu.DisplayInfoBAudioLevelMeterOnoff"]
    /// Every output option above, read once connected.
    static var outputOptionNames: [String] {
        Array(Set(frameLineSelect.values).union(infoSetSelect.values).union(audioMeterInInfoSet.values)).sorted()
    }
    static let userFrameB = (first: "P.System.Menu.MarkerBUserBoxOnoff", second: "P.System.Menu.MarkerBUserBox2Onoff")
    /// The audio meters, {"ch.1": 0–24, …}, and their coarse twin, which the camera sends with them several times a second.
    static let audioMeters = "Output.Audio.dBLevel"
    static let audioLevels = "Output.Audio.Level"
    /// "1" while S&Q runs at 1×, which records sound.
    static let slowAndQuickAtOneTimes = "P.System.Menu.SandQPseudoFixed"
    // VENICE 2's look (LUTConverter.js): its mode (PresetLook, User3D, ART), the preset, the user 3D LUT or ART file
    // chosen (1-based slots), and the lists behind them.
    static let lookMode = "LUT.Mode"
    static let lookPreset = "LUT.Preset"
    static let lookUserFileID = "LUT.User3DLUT.FileID"
    static let lookUserFileName = "LUT.User3DLUT.FileName"
    static let lookARTFileID = "LUT.ART.FileID"
    static let lookARTFileName = "LUT.ART.FileName"
    static let userLUTList = "LUT.User3DLUT.LoadedList"
    static let artList = "LUT.ART.FileList"
    /// The lock on loading a user 3D LUT (the page's VAL_INH_LOAD_SD_CARD), and on the LUT controls as a whole.
    static let userLUTLoad = "LUT.User3DLUT.LoadFile"
    static let lutLock = "Control.LUT.AllItems"
    static let ndNumbers: [Double] = [1, 2, 4, 8, 16, 32, 64, 128, 256]

    /// The page's names for the presets: R709(800%) for VENICE 2's "R709_800%".
    static func presetLabel(_ raw: String) -> String { raw == "R709_800%" ? "R709(800%)" : raw }
    static func presetValue(_ label: String) -> String { label == "R709(800%)" ? "R709_800%" : label }

    /// A user 3D LUT or ART slot with nothing loaded: VENICE 2 fills those with the factory "s709" (no extension; a
    /// loaded file keeps its own, "s709.cube").
    static func isEmptySlot(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "s709" || n == "No File"
    }

    static func ndValue(for label: String) -> Int? {
        guard let index = ndLabels.firstIndex(of: label), ndNumbers.indices.contains(index) else { return nil }
        return Int(ndNumbers[index])
    }

    static func ndLabel(for value: MPValue) -> String {
        if let s = value.string, let index = ndLabels.firstIndex(of: s) { return ndLabels[index] }
        let number = value.unwrapped.number ?? 0
        if let index = ndNumbers.firstIndex(where: { abs($0 - number) < 0.5 }) { return ndLabels[index] }
        if number > 1, number <= 256 {  // a raw density: 0.3 … 2.4
            let density = log2(number)
            return String(format: "%.1f", density)
        }
        return value.description
    }

    /// The socket was refused outright (nothing listening, or a VENICE still holding its last client).
    static func isRefused(_ error: Error) -> Bool {
        if let url = error as? URLError { return url.code == .cannotConnectToHost }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost
    }

    /// Whether the base ISO reads high: 0 / 1 (VENICE 1's page), or "ISO 3200" / "ISO 2500" (VENICE 2).
    static func baseIsHigh(_ value: MPValue?, pair: (Int, Int)) -> Bool {
        guard let value else { return false }
        if let text = value.string ?? value.unwrapped.string, text.uppercased().hasPrefix("ISO") {
            let digits = Int(text.filter(\.isNumber)) ?? 0
            return digits >= pair.1
        }
        return (value.number ?? 0) >= 1
    }

    /// Dual base ISO by body: VENICE 2 is 800/3200, VENICE 1 500/2500. Refined once the camera names its model.
    static func baseISOPair(model: String?) -> (Int, Int) {
        let m = model ?? ""
        return m.contains("3610") || m.contains("3626") ? (500, 2500) : (800, 3200)  // VENICE 1 and VENICE 2 6K: 500/2500
    }

    /// The pair the camera's own reading belongs to ("ISO 500" is a 6K sensor's, whatever the model says), else by body.
    static func baseISOPair(model: String?, reading: MPValue?) -> (Int, Int) {
        if let text = reading?.string ?? reading?.unwrapped.string, text.uppercased().hasPrefix("ISO") {
            switch Int(text.filter(\.isNumber)) {
            case 500, 2500: return (500, 2500)
            case 800, 3200: return (800, 3200)
            default: break
            }
        }
        return baseISOPair(model: model)
    }
    static let wbPresets = VeniceTables.whiteBalanceSteps

    /// The camera's white balance steps, from its three capability lists (Value, Tint, Type, item for item).
    var wbSteps: [(label: String, kelvin: Int, tint: Int, type: String)] {
        let ks = options["Camera.WhiteBalance.ColorTemperature.Value"]?.compactMap { $0.number.map { Int($0) } } ?? []
        let ts = options["Camera.WhiteBalance.ColorTemperature.Tint.Value"]?.compactMap { $0.number.map { Int($0) } } ?? []
        let types = options["Camera.WhiteBalance.ColorTemperature.Type"]?.compactMap(\.string) ?? []
        var seen = Set<String>()
        return ks.enumerated().compactMap { i, k in
            let t = i < ts.count ? ts[i] : 0
            let label = Self.wbLabel(kelvin: k, tint: t)
            guard seen.insert(label).inserted else { return nil }
            return (label, k, t, i < types.count ? types[i] : "User")
        }
    }

    /// "5600K", or "4200K +8" with a tint.
    static func wbLabel(kelvin: Int, tint: Int) -> String {
        tint == 0 ? "\(kelvin)K" : "\(kelvin)K \(tint > 0 ? "+" : "")\(tint)"
    }

    /// The step a Kelvin value sits on, or the value itself between steps.
    static func wbPreset(forKelvin kelvin: Double, tint: Double) -> String {
        let label = "\(Int(kelvin.rounded()))K"
        return wbPresets.contains(label) && tint == 0 ? label : label
    }

    /// VENICE 2 reads speeds with two decimals ("1/24.00", "1/47.95"): shown without ".00".
    static func speedLabel(_ raw: String) -> String {
        raw.hasSuffix(".00") ? String(raw.dropLast(3)) : raw
    }

    /// And takes them back that way: "1/50" → "1/50.00", "1/47.9" → "1/47.90" (ShutterConverter.js).
    static func speedValue(_ label: String) -> String {
        guard let dot = label.lastIndex(of: ".") else { return label + ".00" }
        return label.distance(from: dot, to: label.endIndex) == 2 ? label + "0" : label
    }

    static func angleString(_ angle: Double) -> String {
        angle == angle.rounded() ? String(format: "%.1f", angle) : String(angle)
    }

    static func fpsLabel(_ number: Double) -> String {
        let t = number.rounded()
        return number < t - 0.01 || number > t + 0.01 ? String(format: "%.2f", number) : String(Int(t))  // 23.98, not 23.976024…
    }

    static func parseTimecode(_ text: String) -> (h: Int, m: Int, s: Int, f: Int)? {
        let bits = text.split(separator: ":").compactMap { Int($0) }
        guard bits.count == 4 else { return nil }
        return (bits[0], bits[1], bits[2], bits[3])
    }

    /// The timecode's frame count per second and the real frame rate it runs at, from the project rate: 23.98 counts 24
    /// at 23.976, 25 counts 25, 29.97 counts 30. 47.95, 50 and 59.94 count in frame pairs (24, 25, 30, SMPTE 12M) until
    /// the camera sends a frame number that says it counts them all.
    static func timecodeRates(project: String?, highestFrame: Int) -> (rate: Int, fps: Double) {
        let rate = Double(project ?? "") ?? 24
        let nominal = max(Int(rate.rounded()), 1)
        let ntsc = abs(rate - rate.rounded()) > 0.01
        let counted = nominal >= 48 && highestFrame < nominal / 2 ? nominal / 2 : nominal
        return (counted, Double(counted) * (ntsc ? 1000.0 / 1001.0 : 1))
    }
}

// MARK: - Loading LUTs (VENICE 2)

extension VeniceCameraBackend: LUTImportCapable {
    /// The largest file the camera's page uploads (Const.UPLOAD_FILE_SIZE_MAX), and the longest name (under 64
    /// characters, ".cube" included: Const.USER_LUT_FILE_NAME_LENGTH_MAX).
    static let largestLUT = 9_886_500
    static let longestLUTName = 63

    /// The sixteen user 3D LUT slots, as the camera lists them now; a slot still on the factory s709 is empty.
    public func lutSlots() async throws -> [LUTSlot] {
        guard state.connection == .connected else { throw LUTImportError.notConnected }
        guard values[Self.lookMode] != nil else { throw LUTImportError.notSupported("no user 3D LUTs on this camera") }
        let list = await client.options(for: Self.userLUTList)
        if !list.isEmpty { options[Self.userLUTList] = list }
        let names = options[Self.userLUTList]?.map { $0.string ?? "" } ?? []
        guard !names.isEmpty else { throw LUTImportError.other("The camera didn't list its LUT slots. Try again.") }
        return (1...16).map { index in
            let name = names.indices.contains(index - 1) ? names[index - 1] : ""
            return LUTSlot(index: index, name: Self.isEmptySlot(name) ? nil : name)
        }
    }

    /// Uploads a .cube into a user 3D LUT slot the way the camera's page does (`SavonaClient.upload`), under the name
    /// given: characters the camera's file names can't hold become "_", and ".cube" goes on the end.
    public func importLUT(data: Data, name: String, slot: Int) async throws {
        guard state.connection == .connected else { throw LUTImportError.notConnected }
        guard (1...16).contains(slot) else { throw LUTImportError.other("The camera has user LUT slots 1 to 16.") }
        guard data.count <= Self.largestLUT else { throw LUTImportError.tooLarge }
        guard state.recording.state != .recording, statuses[Self.userLUTLoad] != "Locked" else { throw LUTImportError.busy }
        guard let fileName = Self.cubeFileName(name) else { throw LUTImportError.invalidName }
        let (status, body) = await client.upload(path: "/cgi-bin/upload.cgi", fields: [("DestinationID", String(slot))],
                                                 fileField: "FileName", fileName: fileName, data: data)
        log.notice("LUT upload \(fileName, privacy: .public) → slot \(slot, privacy: .public): HTTP \(status, privacy: .public)")
        ActivityLog.shared.note(host, "VENICE LUT upload \(fileName) to \(slot): HTTP \(status)")
        switch status {
        case 200..<300: break
        case 0: throw body.localizedCaseInsensitiveContains("timed out") ? LUTImportError.timeout
            : LUTImportError.other("The upload didn't reach the camera (\(body.prefix(80))).")
        case 401, 403: throw LUTImportError.other("The camera refused the password for the upload (HTTP \(status)).")
        case 413: throw LUTImportError.tooLarge
        default: throw LUTImportError.other("The camera refused the file (HTTP \(status)).")
        }
        // The slot's new name: the camera's list, fresh (it also says so by notification, which `change` takes).
        try? await Task.sleep(for: .seconds(1))
        let list = await client.options(for: Self.userLUTList)
        if !list.isEmpty { options[Self.userLUTList] = list }
        rebuild()
        yield()
    }

    /// The name a LUT goes onto the camera as: its page's rule (letters, digits and ` #$%&'()+,-.;=@[]^_`{}~`, under 64
    /// characters with ".cube"), anything else as "_". Nil when nothing is left.
    static func cubeFileName(_ name: String) -> String? {
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".cube") { stem = String(stem.dropLast(5)) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ #$%&'()+,-.;=@[]^`{}~")
        stem = String(stem.map { allowed.contains($0) ? $0 : "_" }.prefix(longestLUTName - 5))
            .trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty, stem.contains(where: { $0 != "_" && $0 != "." }) else { return nil }
        return stem + ".cube"
    }
}

extension Double {
    func rounded(stepsOf step: Double) -> Double {
        (self / step).rounded() * step
    }
}
