import CameraCore
import Foundation

// What Tiles reads off an ARRI camera's Web Remote variables, and what it writes back. The names known to be on the
// cameras come first; the rest are guesses in the same naming style (`System…`, `Rec…`, `Lens…`) with a word match behind them, so whichever the camera has is used and anything
// it lacks stays nil — a gray tile, not a wrong one. The first session with a camera replaces guesses with names.

/// A Tiles control and the camera variables that can carry it.
public enum ArriField: String, CaseIterable, Sendable {
    case model, serial, firmware
    case recState, timecode, clipName, reel, clipNumber, cameraIndex
    case ei, eiActual, nd, ndEffective
    case kelvin, tint
    case shutterAngle, shutterIsAngle
    case fps, fpsEffective, projectRate
    case sensorMode, codec, look, desqueeze, colorBars, imageFlip
    case lensIris, lensFocus, lensFocal, lensModel
    case batteryPercent, batteryVoltage, mediaRemaining
    case playbackSpeed, playbackClipIndex, clipCountA, clipCountB, clipTableA, clipTableB
    case reelCardA, reelCardB

    /// Exact names, the verified ones first.
    public var candidates: [String] {
        switch self {
        case .model: ["SystemCameraType", "CameraType", "SystemCameraModel", "CameraModel"]
        case .serial: ["SystemCameraSerial", "CameraSerial", "SystemSerialNumber", "CameraSerialNumber"]
        case .firmware: ["SystemSupVersion", "SupVersion", "SystemSoftwareVersion", "SoftwareVersion", "SystemSUPVersion"]
        case .recState: ["MajorState", "CameraState", "SystemCameraState", "RecState", "RecordingState", "RecStatus",
                         "RecIsRecording", "RecordingActive", "RecActive"]
        case .timecode: ["Timecode", "TimecodeCurrent", "TimeCode", "TCCurrent", "TcCurrent", "TimecodeValue",
                         "SystemTimecode", "RecTimecode"]
        case .clipName: ["ClipName", "ClipNameCurrent", "ClipNameNext", "NextClipName", "RecClipName", "ClipNameFull"]
        case .reel: ["ClipNameReelCount", "ReelCount", "CurrentReel", "RecReelCount", "ClipNameReel", "ReelNumber"]
        case .clipNumber: ["ClipNameClipCount", "ClipNumber", "RecClipCount", "ClipNameClipNumber", "ClipCounter"]
        case .cameraIndex: ["SystemCameraIndex", "ClipNameCameraIndex", "RecCameraIndex", "CameraIndex"]
        case .ei: ["ExposureIndex"]
        case .eiActual: ["ActExposureIndexIso", "ExposureIndexActual"]
        case .nd: ["NDFilterPosition"]
        case .ndEffective: ["NDFilterPositionEffective"]
        case .kelvin: ["WBCurrentKelvin"]
        case .tint: ["WBCurrentColorComp"]
        case .shutterAngle: ["ShutterNominal"]
        case .shutterIsAngle: ["ExposurePreferenceIsAngle"]
        case .fps: ["FPSNominal"]
        case .fpsEffective: ["FPSEffective"]
        case .projectRate: ["ProjectRate", "SystemProjectRate", "ProjectFps", "ProjectFPS", "FPSProject",
                            "ProjectFrameRate"]
        case .sensorMode: ["SensorFormat", "SensorMode", "RecSensorMode", "SensorModeIndex", "RecordingSensorMode",
                           "RecResolution", "RecordingResolution"]
        case .codec: ["RecCodecType", "RecCodec", "RecordingCodec", "Codec", "RecFormat", "RecordingFormat"]
        case .look: ["LookFileName", "LookFilename", "LookName", "CurrentLookName", "LookCurrentName", "LookFile",
                     "ActiveLook"]
        case .desqueeze: ["LensSqueezeFactor", "AnamorphicDesqueeze", "MonitoringDesqueeze", "Desqueeze",
                          "DesqueezeFactor", "AnamorphicSqueeze", "SqueezeFactor"]
        // An ALEXA Mini's color bars are SDI1TestImageIsActive: what its menu's Color bars and its COLOR_BAR user button
        // switch (SMPTE bars on the SDI outputs, in standby only, and REC turns them off: SUP 6.1 manual p. 93).
        case .colorBars: ["SDI1TestImageIsActive", "TestImage", "TestSignal", "ColorBars", "ColorBar", "TestPattern"]
        case .imageFlip: ["SensorImageFlip", "ImageFlip", "SensorFlip", "FlipImage", "ImageOrientation",
                          "SensorOrientation"]
        case .lensIris: ["LensIris", "LdsLensIris", "LensIrisValue", "LensTStop", "LdsIris"]
        case .lensFocus: ["LensFocus", "LdsLensFocus", "LensFocusDistance", "LdsFocusDistance", "LDSFocusValueMetric"]
        case .lensFocal: ["LensFocalLength", "LdsLensFocalLength", "LensZoom", "LdsFocalLength", "LDSZoomValue"]
        case .lensModel: ["LensModelName", "LdsLensModel", "LensModel", "LensName"]
        case .batteryPercent: ["BatteryCapacity", "PowerBatteryCapacity", "BatteryPercent", "BatteryCharge",
                               "BatteryLevel", "Bat1LevelPercent"]
        case .batteryVoltage: ["BatteryVoltage", "PowerBatteryVoltage", "SystemBatteryVoltage", "MainVoltage",
                               "PowerMainVoltage", "PowerVoltage", "SupplyVoltage", "Bat2LevelVolt"]
        case .mediaRemaining: ["RemainingRecTime", "RecRemainingTime", "MediaRemainingTime", "RecRemainingMinutes",
                               "MediumRemainingTime", "CardARemainingTime", "MediaRemaining"]
        case .playbackSpeed: ["PlaybackSpeedEnum"]
        case .playbackClipIndex: ["PlaybackClipIndex"]
        case .clipCountA: ["ClipCountCardA"]
        case .clipCountB: ["ClipCountCardB"]
        case .clipTableA: ["ClipTableCardAVersion"]
        case .clipTableB: ["ClipTableCardBVersion"]
        case .reelCardA: ["ReelCountCardA", "ClipNameReelCountCardA", "ReelCountA"]
        case .reelCardB: ["ReelCountCardB", "ClipNameReelCountCardB", "ReelCountB"]
        }
    }

    /// For a name the list missed: every word of one set in the name, none of the excluded words. Verified names have
    /// none, so a near-miss can't take over a control that's known exactly.
    var wordSets: [[String]] {
        switch self {
        case .model: [["camera", "type"], ["camera", "model"]]
        case .serial: [["camera", "serial"]]
        case .recState: [["rec", "state"], ["rec", "status"], ["camera", "state"], ["recording", "active"],
                         ["is", "recording"]]
        case .timecode: [["timecode"]]
        case .clipName: [["clip", "name"]]
        case .reel: [["reel"]]
        case .clipNumber: [["clip", "number"], ["clip", "counter"]]
        case .cameraIndex: [["camera", "index"]]
        case .projectRate: [["project", "rate"], ["project", "fps"]]
        case .sensorMode: [["sensor", "mode"]]
        case .codec: [["codec"]]
        case .look: [["look", "name"], ["look", "file"]]
        case .desqueeze: [["squeeze"]]
        case .colorBars: [["test", "image"], ["color", "bar"], ["test", "signal"], ["test", "pattern"]]
        case .imageFlip: [["flip"], ["image", "orientation"]]
        // No word match for the iris or focus: on an ALEXA Mini it found button locks and overlay switches
        // (ButtonLensIrisShallLock, EVFStatusLensFocusIsOn). The Mini's iris is read from LDSIrisFullStops instead.
        case .lensFocal: [["focal"]]
        case .batteryPercent: [["battery", "capacity"], ["battery", "percent"]]
        case .batteryVoltage: [["battery", "voltage"], ["main", "voltage"]]
        case .mediaRemaining: [["remaining", "time"], ["remaining", "min"]]
        default: []
        }
    }

    var excludedWords: [String] {
        switch self {
        case .recState: ["playback", "medium", "media", "mode", "format", "list", "count", "time", "possible", "beep"]
        // The ALEXA Mini's TC comes as TimecodeHours / Minutes / Seconds (ArriReading.timecodeParts); its
        // …StatusTimecodeIsOn are overlay switches.
        case .timecode: ["offset", "mode", "drop", "run", "init", "source", "format", "user", "status", "hours",
                         "minutes", "seconds", "warning"]
        case .clipName: ["index", "reel", "count", "format", "mode", "type", "prefix", "camera", "list"]
        case .reel: ["index", "list", "mode"]
        case .clipNumber: ["card", "list", "table"]
        case .look: ["list", "switch", "count", "path", "install", "library"]
        case .sensorMode: ["list"]
        case .codec: ["list"]
        case .mediaRemaining: ["battery", "power"]
        case .imageFlip: ["frameline", "evf", "sdi", "mon"]
        // A Mini's other test images (EVF…, Monitor…, SDI2TestImageIsActive) aren't its color bars: by name above.
        case .colorBars: ["evf", "sdi", "monitor"]
        default: []
        }
    }
}

/// Splits a camel-case name into its words: "WBCurrentKelvin" → wb current kelvin, "SDI1Frameline" → sdi 1 frameline.
public enum ArriNames {
    private static let wordPattern =
        try! NSRegularExpression(pattern: #"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d+"#)

    public static func words(_ name: String) -> [String] {
        let ns = name as NSString
        return wordPattern.matches(in: name, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    /// A word of `name` starts with `word`, or (for a long word) the whole name holds it: "timecode" is in TimeCode.
    static func has(_ word: String, words: [String], name lowercased: String) -> Bool {
        words.contains { $0.hasPrefix(word) } || (word.count >= 5 && lowercased.contains(word))
    }

    /// Resolves every field against the camera's names: an exact candidate, else a word match among names no other
    /// field took exactly. The camera's UI-only variables (a leading "_") are never matched by words.
    public static func resolve(_ names: Set<String>) -> [ArriField: String] {
        var found: [ArriField: String] = [:]
        for field in ArriField.allCases {
            if let exact = field.candidates.first(where: names.contains) { found[field] = exact }
        }
        let taken = Set(found.values)
        let pool = names.filter { !$0.hasPrefix("_") && !taken.contains($0) }.sorted()
            .map { (name: $0, words: words($0), lower: $0.lowercased()) }
        for field in ArriField.allCases where found[field] == nil && !field.wordSets.isEmpty {
            let match = pool.first { entry in
                guard !field.excludedWords.contains(where: { has($0, words: entry.words, name: entry.lower) }) else { return false }
                return field.wordSets.contains { set in set.allSatisfy { has($0, words: entry.words, name: entry.lower) } }
            }
            if let match, !found.values.contains(match.name) { found[field] = match.name }
        }
        return found
    }
}

// MARK: - Outputs and their overlays

/// One switch on one output: the variable, and the values that mean on and off.
public struct ArriSwitch: Sendable, Equatable {
    public var variable: String
    public var on: ArriValue
    public var off: ArriValue

    /// Whether the camera lets this switch go both ways now: for an enum, both its values selectable. With SDI 2
    /// clean, an ALEXA Mini offers its look switch only Look, and a write of Log C comes back refused.
    public func canSwitch(_ variable: ArriVariable) -> Bool {
        guard variable.isEnum, let a = on.number?.asInt, let b = off.number?.asInt else { return true }
        return variable.selectable(a) && variable.selectable(b)
    }

    public func isOn(_ value: ArriValue) -> Bool? {
        if value == on { return true }
        if value == off { return false }
        if case .bool(let b) = on, case .bool = off { return value.bool ?? !b }
        // A multi-way enum (exposure tool: off / false color / zebra): anything but `on` is off for this overlay.
        if value.number != nil, on.number != nil { return false }
        return nil
    }
}

/// An output the camera sets overlays on, by the token its variables carry ("Evf", "Sdi1", "Mon2").
public struct ArriOutput: Sendable, Equatable {
    public var id: String
    public var name: String
    public var switches: [MonitorOverlay: ArriSwitch]
}

public enum ArriOutputs {
    /// Outputs in the camera's order of importance: SDI, then the viewfinder, then monitors.
    static let order = ["Sdi1", "Sdi2", "Sdi3", "Sdi4", "Sdi", "Evf", "Mon", "Mon1", "Mon2", "Mon3", "Hdmi"]

    /// Finds, from the variables' names, which outputs have which overlay switches. A variable names its output
    /// ("…Evf…", "…Sdi1…", "…Mon2…") and its overlay ("Look", "Frameline", "FalseColor", "Zebra", "Peaking",
    /// "ExposureTool", "FocusTool", "Overlay"); it counts when it's a switch the camera can read as on or off: a bool,
    /// a 0–1 number, or an enum with an "off" choice and one that means this overlay.
    public static func detect(_ snapshot: ArriSnapshot, catalog: ArriEnumCatalog) -> [ArriOutput] {
        var found: [String: ArriOutput] = [:]
        // In name order, so the same camera always gives the same switches. Events (an ALEXA Mini's
        // MessageEventLookSDIColorSpaceChanged), read-only mirrors (…Effective) and option counts aren't switches.
        for name in snapshot.variables.keys.sorted() where !name.hasPrefix("_") && !name.hasPrefix("Message") {
            let variable = snapshot.variables[name]!
            let w = ArriNames.words(name)
            if w.contains(where: { ["changed", "event", "effective", "options"].contains($0) }) { continue }
            guard let output = outputToken(w) else { continue }
            let rest = w.filter { !output.words.contains($0) }
            let lower = rest.joined()
            for overlay in overlays(rest, joined: lower) {
                guard let sw = switchFor(overlay, name: name, variable: variable, catalog: catalog) else { continue }
                var entry = found[output.id] ?? ArriOutput(id: output.id, name: output.name, switches: [:])
                // A look switch beats a "processed" (Log / Rec 709) one for the LUT; otherwise the first found stays.
                if entry.switches[overlay] == nil || (overlay == .lut && rest.contains("look")) {
                    entry.switches[overlay] = sw
                }
                found[output.id] = entry
            }
        }
        // An ALEXA Mini sets SDI overlays once for both outputs (SDIFramelinesAreOn…) and the look per output
        // (SDI1PathProcessing, SDI2PathProcessing): the shared switches join each numbered SDI.
        if let shared = found["Sdi"], found.keys.contains(where: { $0.hasPrefix("Sdi") && $0 != "Sdi" }) {
            for id in found.keys where id.hasPrefix("Sdi") && id != "Sdi" {
                found[id]!.switches.merge(shared.switches) { own, _ in own }
            }
            found["Sdi"] = nil
        }
        return found.values.sorted { a, b in
            (order.firstIndex(of: a.id) ?? 99, a.id) < (order.firstIndex(of: b.id) ?? 99, b.id)
        }
    }

    static func outputToken(_ words: [String]) -> (id: String, name: String, words: Set<String>)? {
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            let digit = next.flatMap { Int($0) }
            switch word {
            case "evf", "vf": return ("Evf", "EVF", [word])
            case "sdi": return digit.map { ("Sdi\($0)", "SDI \($0)", [word, next!]) } ?? ("Sdi", "SDI", [word])
            case "mon", "monitor": return digit.map { ("Mon\($0)", "MON \($0)", [word, next!]) } ?? ("Mon", "MON", [word])
            case "hdmi": return ("Hdmi", "HDMI", [word])
            default: continue
            }
        }
        return nil
    }

    static func overlays(_ words: [String], joined: String) -> [MonitorOverlay] {
        func has(_ w: String) -> Bool { ArriNames.has(w, words: words, name: joined) }
        let blocked = ["level", "threshold", "opacity", "intensity", "brightness", "list", "count", "name", "file",
                       "width", "position", "size", "aspect", "ratio", "zoom", "magnif", "mode", "hidden"]
        if blocked.contains(where: has) { return [] }
        var list: [MonitorOverlay] = []
        // The look: a switch naming it, or the Mini's path processing (Log C / Look / ALEXA Classic 709).
        if has("look") || has("lut") || has("processed") || (has("path") && has("processing")) { list.append(.lut) }
        if (has("frameline") || (has("frame") && has("line"))) && !has("color") && !has("colour") {
            list.append(.frameGuides)
        }
        if has("falsecolor") || (has("false") && (has("color") || has("colour"))) { list.append(.falseColor) }
        if has("zebra") { list.append(.zebra) }
        if has("exposure") && has("tool") { list.append(contentsOf: [.falseColor, .zebra]) }
        if has("peaking") || (has("focus") && (has("tool") || has("assist"))) { list.append(.focusAssist) }
        if has("overlay") || has("osd") || (has("status") && has("info")) { list.append(.statusText) }
        // An ALEXA Mini's SDI 1/2 image (SDI1Processing, SDI2Processing): Clean or Processed (`switchFor`).
        if has("processing") && !has("path") { list.append(.cleanFeed) }
        return Array(Set(list)).sorted { $0.rawValue < $1.rawValue }
    }

    /// The values that turn `overlay` on and off with this variable, if it's a switch.
    static func switchFor(_ overlay: MonitorOverlay, name: String, variable: ArriVariable,
                          catalog: ArriEnumCatalog) -> ArriSwitch? {
        if variable.isEnum {
            let labels = variable.enumIndexes.map { ($0, catalog.label(variable: name, index: $0)?.lowercased() ?? "") }
            guard labels.contains(where: { !$0.1.isEmpty }) else { return nil }
            func first(_ test: (String) -> Bool) -> Int? { labels.first { test($0.1) }?.0 }
            if overlay == .cleanFeed {
                // Clean: "identical to the images that the camera records internally", no overlays and no surround
                // view; Processed may have both (ALEXA Mini SUP 6.1 manual p. 91, MENU > Monitoring > SDI > SDI 1
                // image). Only one SDI processed, unless SDI 2 clones SDI 1: the camera says so in its selectable
                // flags, which gray the switch.
                guard let on = first({ $0 == "clean" }), let off = first({ $0.hasPrefix("processed") }) else { return nil }
                return ArriSwitch(variable: name, on: .number(Double(on)), off: .number(Double(off)))
            }
            guard let off = first({ ["off", "none", "disabled", "disable", "hide", "no"].contains($0)
                                    || $0.hasPrefix("off") || $0 == "log" || $0 == "log c" || $0 == "logc" }) else { return nil }
            let on: Int?
            switch overlay {
            case .falseColor: on = first { $0.contains("false") }
            case .zebra: on = first { $0.contains("zebra") }
            case .focusAssist: on = first { $0.contains("peak") || $0.contains("focus") } ?? first { $0 == "on" }
            case .lut: on = first { $0.contains("look") || $0.contains("709") || $0.contains("lut") }
                ?? first { $0 == "on" || $0 == "enabled" }
            default: on = first { $0 == "on" || $0 == "enabled" || $0 == "show" || $0 == "enable" }
                ?? (labels.count == 2 ? labels.first { $0.0 != off }?.0 : nil)
            }
            guard let on, on != off else { return nil }
            return ArriSwitch(variable: name, on: .number(Double(on)), off: .number(Double(off)))
        }
        if variable.isBool || { if case .bool = variable.value { return true }; return false }() {
            // "Processed" reads true for Rec 709 (a look) and false for Log C.
            return ArriSwitch(variable: name, on: .bool(true), off: .bool(false))
        }
        if variable.min == 0, variable.max == 1 {
            return ArriSwitch(variable: name, on: .number(1), off: .number(0))
        }
        return nil
    }
}

// MARK: - Reading a camera

/// One camera as Tiles reads it: the variables, the page script's enums, and which variable carries which control.
public struct ArriReading: Sendable {
    public var snapshot: ArriSnapshot
    public var catalog: ArriEnumCatalog
    public var fields: [ArriField: String]
    public var outputs: [ArriOutput]

    public init(snapshot: ArriSnapshot, catalog: ArriEnumCatalog) {
        self.snapshot = snapshot
        self.catalog = catalog
        fields = ArriNames.resolve(Set(snapshot.variables.keys))
        outputs = ArriOutputs.detect(snapshot, catalog: catalog)
    }

    public func variable(_ field: ArriField) -> ArriVariable? {
        fields[field].flatMap { snapshot.variables[$0] }
    }

    public func value(_ field: ArriField) -> ArriValue? { variable(field)?.value }

    /// An enum's label for its current value, or a text value, or a number as written.
    public func text(_ field: ArriField) -> String? {
        guard let name = fields[field], let variable = snapshot.variables[name] else { return nil }
        if variable.isEnum {
            return variable.value.number?.asInt.flatMap { catalog.label(variable: name, index: $0) }
        }
        switch variable.value {
        case .string(let s): return s.trimmingCharacters(in: .whitespaces)
        case .number(let n): return ArriFormat.number(n)
        case .bool(let b): return b ? "On" : "Off"
        default: return nil
        }
    }

    /// An enum's choices the camera lets be picked now: (index, label), in its order.
    public func choices(_ field: ArriField) -> [(index: Int, label: String)] {
        guard let name = fields[field], let variable = snapshot.variables[name], variable.isEnum else { return [] }
        return variable.enumIndexes.filter(variable.selectable).compactMap { index in
            catalog.label(variable: name, index: index).map { (index, $0) }
        }
    }

    /// Whether the camera says it's recording: a bool, or a state whose label says so. Nil when it can't be told (no
    /// such variable, or a number without the page script's labels), so REC is then trusted on the camera's acceptance
    /// rather than read as stopped.
    public func recording() -> Bool? {
        guard let variable = variable(.recState) else { return nil }
        if case .bool(let b) = variable.value { return b }
        guard let label = text(.recState), Double(label) == nil, !label.isEmpty else { return nil }
        return Self.isRecording(label)
    }

    static func isRecording(_ label: String) -> Bool {
        let text = label.lowercased()
        if ["ready", "standby", "stop", "idle", "pause", "play", "prepar", "prerec", "not"].contains(where: text.contains) {
            return false
        }
        return text.contains("rec")
    }

    public func isWritable(_ field: ArriField) -> Bool {
        guard let variable = variable(field) else { return false }
        return !variable.readOnly
    }

    /// The index whose label means `label` (as Tiles shows it, after `normalise`).
    public func index(of label: String, in field: ArriField, normalise: (String) -> String = { $0 }) -> Int? {
        guard let name = fields[field], let variable = snapshot.variables[name], variable.isEnum else { return nil }
        let wanted = normalise(label)
        return variable.enumIndexes.first { index in
            catalog.label(variable: name, index: index).map(normalise) == wanted
        }
    }
}

/// How ARRI's values read as Tiles shows them.
public enum ArriFormat {
    public static func number(_ n: Double) -> String {
        if n == n.rounded() { return String(Int(n)) }
        var text = String(format: "%.3f", n)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "ND  -", "CLEAR", "Clear" → "Clear"; "ND 0.6" → "0.6"; tokens spelled out ("ONE_POINT_TWO") → "1.2".
    public static func ndLabel(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower == "nd -" || lower == "nd  -" || lower.hasSuffix("-") || lower.contains("clear") || lower == "off"
            || lower == "nd 0" || lower == "0" { return "Clear" }
        if let number = ArriEnumCatalog.firstGroup(#"(\d+(?:\.\d+)?)"#, in: text) { return number }
        if let spelled = spelledNumber(lower) { return spelled }
        return text
    }

    /// "zero point six" / "two_point_one" → "0.6" / "2.1".
    static func spelledNumber(_ text: String) -> String? {
        let digits = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                      "seven": "7", "eight": "8", "nine": "9", "point": "."]
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ digits[$0] != nil }) else { return nil }
        return parts.map { digits[$0]! }.joined()
    }

    /// The first whole number in an EI label ("800", "EI 800", "EI_800").
    public static func eiNumber(_ label: String) -> Int? {
        ArriEnumCatalog.firstGroup(#"(\d+)"#, in: label).flatMap(Int.init)
    }

    /// Timecode as text ("01:02:03:04", "01:02:03;04") or BCD (0x01020304: each byte one field, MSB first).
    public static func timecode(_ value: ArriValue) -> (h: Int, m: Int, s: Int, f: Int)? {
        if let text = value.string {
            let bits = text.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
            return bits.count == 4 ? (bits[0], bits[1], bits[2], bits[3]) : nil
        }
        guard let n = value.number, n >= 0, n < 4_294_967_296 else { return nil }
        let raw = UInt32(n)
        func bcd(_ shift: UInt32) -> Int? {
            let byte = (raw >> shift) & 0xFF
            let hi = Int(byte >> 4), lo = Int(byte & 0x0F)
            return hi < 10 && lo < 10 ? hi * 10 + lo : nil
        }
        guard let h = bcd(24), let m = bcd(16), let s = bcd(8), let f = bcd(0), h < 24, m < 60, s < 60 else { return nil }
        return (h, m, s, f)
    }

    /// A lens iris as a T-number: given as one (0.5…64), or in thousandths of a stop (3000 is T2.8).
    public static func tStop(_ raw: Double) -> Double? {
        if raw >= 0.5, raw <= 64 { return (raw * 10).rounded() / 10 }
        if raw >= 100, raw <= 20_000 { return (pow(2, raw / 2000) * 10).rounded() / 10 }
        return nil
    }

    /// Minutes of media left from a figure in minutes or seconds (over ten hours of minutes reads as seconds).
    public static func minutes(_ raw: Double) -> Int? {
        guard raw >= 0 else { return nil }
        return (raw > 600 ? raw / 60 : raw).asInt
    }

    /// A letter from an index enum's label ("A") or a 0-based number (0 is A).
    public static func letter(_ value: ArriValue, label: String?) -> String? {
        if let label, label.count == 1, label.first?.isLetter == true { return label.uppercased() }
        if let s = value.string, s.count == 1 { return s.uppercased() }
        if let n = value.number?.asInt, n >= 0, n < 26 { return String(UnicodeScalar(UInt8(65 + n))) }
        return nil
    }
}
