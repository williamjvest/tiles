import CameraCore
import Foundation

// Settings Camera 10.3.1's API hasn't got, reached through its presets: each output's status text and what it shows
// (SDI's for the director or the cinematographer), and the anamorphic de-squeeze. A preset is the camera's whole
// state. The API saves the current state as one (PUT /presets/{name}), sends it (GET), takes one back (POST) and
// loads it (PUT /presets/active), so a setting is changed by saving the state, changing that one value and loading
// the result: the camera changes that and nothing else. Checked on a PYXIS 12K (Camera 10.3.1),
// field by field: docs/pyxis-controls.md, Presets. A PYXIS on other software has its presets used when they're laid out
// as 10.3.1's (`PresetFile.layoutMismatch`).

/// Protobuf's wire format, for a message with no published schema: fields kept as they came, so everything but the
/// value changed goes back byte for byte.
enum Proto {
    struct Field: Equatable {
        var number: Int
        /// 0 varint, 1 eight bytes, 2 length-delimited, 5 four bytes.
        var wire: Int
        var varint: UInt64 = 0
        var bytes = Data()
    }

    /// One step down a path: the field, and which of its repeats (0 the first).
    struct Step: Equatable {
        var field: Int
        var index = 0
    }

    static func parse(_ data: Data) -> [Field]? {
        let b = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint(), key >> 3 > 0 else { return nil }
            var field = Field(number: Int(key >> 3), wire: Int(key & 7))
            switch field.wire {
            case 0:
                guard let v = varint() else { return nil }
                field.varint = v
            case 1, 5:
                let n = field.wire == 1 ? 8 : 4
                guard i + n <= b.count else { return nil }
                field.bytes = Data(b[i..<i + n])
                i += n
            case 2:
                guard let n = varint(), i + Int(n) <= b.count else { return nil }
                field.bytes = Data(b[i..<i + Int(n)])
                i += Int(n)
            default:
                return nil
            }
            out.append(field)
        }
        return out
    }

    static func serialize(_ fields: [Field]) -> Data {
        var out = Data()
        func varint(_ v: UInt64) {
            var v = v
            repeat {
                let byte = UInt8(v & 0x7F)
                v >>= 7
                out.append(v == 0 ? byte : byte | 0x80)
            } while v != 0
        }
        for field in fields {
            varint(UInt64(field.number << 3 | field.wire))
            switch field.wire {
            case 0: varint(field.varint)
            case 2: varint(UInt64(field.bytes.count)); out.append(field.bytes)
            default: out.append(field.bytes)
            }
        }
        return out
    }

    /// The varint at `path` in `message`.
    static func value(in message: Data, at path: ArraySlice<Step>) -> UInt64? {
        guard let step = path.first, let fields = parse(message),
              let field = fields.filter({ $0.number == step.field }).dropFirst(step.index).first else { return nil }
        if path.count == 1 { return field.wire == 0 ? field.varint : nil }
        return field.wire == 2 ? value(in: field.bytes, at: path.dropFirst()) : nil
    }

    /// `message` with the varint at `path` set: the field is added at the end of its message if it isn't there (a
    /// message must already exist for each step but the last).
    static func setting(_ value: UInt64, in message: Data, at path: ArraySlice<Step>) throws -> Data {
        guard let step = path.first, var fields = parse(message) else { throw PresetError.unreadable }
        let matches = fields.indices.filter { fields[$0].number == step.field }
        if path.count == 1 {
            if step.index < matches.count {
                guard fields[matches[step.index]].wire == 0 else { throw PresetError.unexpected }
                fields[matches[step.index]].varint = value
            } else if step.index == 0 {
                fields.append(Field(number: step.field, wire: 0, varint: value))
            } else {
                throw PresetError.unexpected
            }
        } else {
            guard step.index < matches.count, fields[matches[step.index]].wire == 2 else { throw PresetError.unexpected }
            let at = matches[step.index]
            fields[at].bytes = try setting(value, in: fields[at].bytes, at: path.dropFirst())
        }
        return serialize(fields)
    }

    /// The bytes (a string, say) at `path` in `message`.
    static func bytes(in message: Data, at path: ArraySlice<Step>) -> Data? {
        guard let step = path.first, let fields = parse(message),
              let field = fields.filter({ $0.number == step.field }).dropFirst(step.index).first, field.wire == 2 else { return nil }
        return path.count == 1 ? field.bytes : bytes(in: field.bytes, at: path.dropFirst())
    }

    /// `message` with the bytes at `path` set (added at the end of its message if it isn't there).
    static func setting(bytes value: Data, in message: Data, at path: ArraySlice<Step>) throws -> Data {
        guard let step = path.first, var fields = parse(message) else { throw PresetError.unreadable }
        let matches = fields.indices.filter { fields[$0].number == step.field }
        if path.count == 1 {
            if step.index < matches.count {
                guard fields[matches[step.index]].wire == 2 else { throw PresetError.unexpected }
                fields[matches[step.index]].bytes = value
            } else if step.index == 0 {
                fields.append(Field(number: step.field, wire: 2, bytes: value))
            } else {
                throw PresetError.unexpected
            }
        } else {
            guard step.index < matches.count, fields[matches[step.index]].wire == 2 else { throw PresetError.unexpected }
            let at = matches[step.index]
            fields[at].bytes = try setting(bytes: value, in: fields[at].bytes, at: path.dropFirst())
        }
        return serialize(fields)
    }

    /// How many times `field` repeats in `message`.
    static func count(of field: Int, in message: Data) -> Int {
        parse(message)?.filter { $0.number == field }.count ?? 0
    }

    /// A field's number and wire type: what a layout is compared by.
    struct Key: Hashable, Comparable, CustomStringConvertible {
        var number: Int
        var wire: Int

        init(_ number: Int, _ wire: Int) {
            self.number = number
            self.wire = wire
        }

        static func < (a: Key, b: Key) -> Bool { (a.number, a.wire) < (b.number, b.wire) }
        var description: String { "\(number) (wire type \(wire))" }
    }
}

extension Proto.Field {
    var key: Proto.Key { Proto.Key(number, wire) }
}

enum PresetError: Error {
    /// Not a preset this code can read.
    case unreadable
    /// A value where the preset has something else (a message where a number was expected, say).
    case unexpected
}

/// A camera preset (.cset): top-level field 1, then field 10 once per section, each {1: name, 2: its settings}.
struct PresetFile: Equatable {
    private(set) var data: Data

    init(_ data: Data) throws {
        guard let fields = Proto.parse(data), !fields.isEmpty else { throw PresetError.unreadable }
        self.data = data
    }

    /// Sections by name: "metering" (each output's monitoring), "transport" (recording), "ui", "lens", …
    private func section(_ name: String) -> (index: Int, settings: Data)? {
        guard let fields = Proto.parse(data) else { return nil }
        for (index, field) in fields.enumerated() where field.number == 10 && field.wire == 2 {
            guard let entry = Proto.parse(field.bytes) else { continue }
            if entry.first(where: { $0.number == 1 }).map({ String(decoding: $0.bytes, as: UTF8.self) }) == name {
                return (index, entry.first { $0.number == 2 }?.bytes ?? Data())
            }
        }
        return nil
    }

    /// Its sections: name and settings, in order.
    private var sectionList: [(name: String, settings: Data)] {
        (Proto.parse(data) ?? []).compactMap { field in
            guard field.number == 10, field.wire == 2, let entry = Proto.parse(field.bytes),
                  let name = entry.first(where: { $0.number == 1 }) else { return nil }
            return (String(decoding: name.bytes, as: UTF8.self), entry.first { $0.number == 2 }?.bytes ?? Data())
        }
    }

    /// The sections whose settings differ from `other`'s.
    func sectionsChanged(from other: PresetFile) -> Set<String> {
        let theirs = Dictionary(other.sectionList.map { ($0.name, $0.settings) }, uniquingKeysWith: { a, _ in a })
        return Set(sectionList.filter { theirs[$0.name] != $0.settings }.map(\.name))
    }

    /// A preset of `names` alone, each section whole as this file has it, with its header. A PYXIS loads the sections a
    /// preset has and leaves the others alone, so a change goes as the section it's in: tried section by section
    /// (docs/pyxis-controls.md, Presets). Never an empty section: loading empty ones reset part of the camera (zebra
    /// and frame guides came on, an output went to clean feed).
    func only(_ names: Set<String>) throws -> PresetFile {
        guard let fields = Proto.parse(data) else { throw PresetError.unreadable }
        var kept: [Proto.Field] = []
        for field in fields {
            guard field.number == 10 else {
                kept.append(field)   // the header
                continue
            }
            guard let entry = Proto.parse(field.bytes),
                  let name = entry.first(where: { $0.number == 1 }).map({ String(decoding: $0.bytes, as: UTF8.self) }),
                  names.contains(name) else { continue }
            guard entry.first(where: { $0.number == 2 })?.bytes.isEmpty == false else { throw PresetError.unexpected }
            kept.append(field)
        }
        let file = try PresetFile(Proto.serialize(kept))
        guard Set(file.sectionNames) == names else { throw PresetError.unexpected }
        return file
    }

    /// Its sections' names, in order.
    var sectionNames: [String] {
        (Proto.parse(data) ?? []).compactMap { field -> String? in
            guard field.number == 10, field.wire == 2, let entry = Proto.parse(field.bytes),
                  let name = entry.first(where: { $0.number == 1 }) else { return nil }
            return String(decoding: name.bytes, as: UTF8.self)
        }
    }

    func value(_ section: String, _ path: [Proto.Step]) -> UInt64? {
        self.section(section).flatMap { Proto.value(in: $0.settings, at: path[...]) }
    }

    func string(_ section: String, _ path: [Proto.Step]) -> String? {
        self.section(section).flatMap { Proto.bytes(in: $0.settings, at: path[...]) }.map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func set(_ section: String, _ path: [Proto.Step], to value: String) throws {
        guard let (index, settings) = self.section(section), var fields = Proto.parse(data),
              var entry = Proto.parse(fields[index].bytes),
              let slot = entry.firstIndex(where: { $0.number == 2 && $0.wire == 2 }) else { throw PresetError.unreadable }
        entry[slot].bytes = try Proto.setting(bytes: Data(value.utf8), in: settings, at: path[...])
        fields[index].bytes = Proto.serialize(entry)
        data = Proto.serialize(fields)
    }

    func count(_ section: String, field: Int) -> Int {
        self.section(section).map { Proto.count(of: field, in: $0.settings) } ?? 0
    }

    mutating func set(_ section: String, _ path: [Proto.Step], to value: UInt64) throws {
        guard let (index, settings) = self.section(section), var fields = Proto.parse(data),
              var entry = Proto.parse(fields[index].bytes),
              let slot = entry.firstIndex(where: { $0.number == 2 && $0.wire == 2 }) else { throw PresetError.unreadable }
        entry[slot].bytes = try Proto.setting(value, in: settings, at: path[...])
        fields[index].bytes = Proto.serialize(entry)
        data = Proto.serialize(fields)
    }
}

/// The settings Tiles keeps through presets, as a camera's preset holds them.
struct PresetSettings: Equatable {
    /// Each output's status text on, and what it shows, in the order the camera lists its outputs (on a PYXIS: LCD,
    /// front USB-C, rear USB-C, SDI).
    var statusText: [Bool]
    var statusTextContent: [StatusTextContent?]
    /// Anamorphic de-squeeze, as `desqueezeFactors` names it; nil when the preset hasn't got it.
    var desqueeze: String?
    /// The LUT in use, by its file name ("Blackmagic Gen 5 Film to Extended Video.cube"): one for the whole camera
    /// (each output's LUT on or off is in the API). A preset holds this one name, not the camera's list of LUTs, and
    /// nothing on the network lists them (the API, the web file manager, FTP and SMB serve media only), so Tiles learns
    /// them as they're used. A name the camera hasn't got, it ignores.
    var lut: String?

    /// "metering": field 32 once per output; in each, 8 is status text and 14 what it shows; 100 the LUT in use.
    /// "transport": 92 is the de-squeeze.
    static let outputs = 32, statusTextField = 8, contentField = 14, desqueezeField = 92, lutField = 100

    /// The camera's de-squeeze steps in its menu's order (the URSA Cine manual's table; the PYXIS manual lists none).
    /// Each checked on a PYXIS 12K by its stream's picture, which is de-squeezed: a 3:2 recording area fills the
    /// 1080p frame's width and 1920 / (1.528 × the factor) of its height.
    static let desqueezeFactors = ["None", "1.33x", "1.5x", "1.6x", "1.66x", "1.8x", "2.0x"]

    /// What an output's status text shows, as the preset numbers it: checked on the camera's menu, SDI's 3 and 4 and
    /// the LCD's 1 and 2 (PYXIS 12K, Camera 10.3.1).
    static let contentCodes: [StatusTextContent: UInt64] = [.meters: 1, .codecAndResolution: 2, .cinematographer: 3, .director: 4]

    init(statusText: [Bool], statusTextContent: [StatusTextContent?], desqueeze: String?, lut: String? = nil) {
        self.statusText = statusText
        self.statusTextContent = statusTextContent
        self.desqueeze = desqueeze
        self.lut = lut
    }

    init(_ file: PresetFile) {
        let count = file.count("metering", field: Self.outputs)
        statusText = (0..<count).map {
            file.value("metering", [Proto.Step(field: Self.outputs, index: $0), Proto.Step(field: Self.statusTextField)]) == 1
        }
        statusTextContent = (0..<count).map { output in
            file.value("metering", [Proto.Step(field: Self.outputs, index: output), Proto.Step(field: Self.contentField)])
                .flatMap { code in Self.contentCodes.first { $0.value == code }?.key }
        }
        desqueeze = file.value("transport", [Proto.Step(field: Self.desqueezeField)])
            .flatMap { Int(exactly: $0) }.flatMap { Self.desqueezeFactors.indices.contains($0) ? Self.desqueezeFactors[$0] : nil }
        lut = file.string("metering", [Proto.Step(field: Self.lutField)]).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension PresetFile {
    /// Where a PYXIS 12K on Camera 10.3.1 keeps what Tiles reads and writes, by field number and wire type: every field
    /// of `transport` (the de-squeeze is 92), of `metering` (an entry per output is 32, the LUT in use 100), and of each
    /// output's entry (LUT on 1, frame guides 2, false color 4, zebra 5, status text 8, clean feed 9, what status text
    /// shows 14; 15 goes to 0 with focus assist on). The camera saves every field, one set to zero too.
    static let checkedTransport: Set<Proto.Key> = [
        .init(1, 2), .init(10, 2), .init(20, 2), .init(21, 2), .init(30, 0), .init(31, 0), .init(40, 0), .init(60, 0),
        .init(80, 0), .init(90, 0), .init(91, 2), .init(92, 0),
    ]
    static let checkedMetering: Set<Proto.Key> = [
        .init(5, 0), .init(6, 0), .init(7, 0), .init(8, 0), .init(9, 0), .init(10, 0), .init(11, 2), .init(17, 0),
        .init(18, 2), .init(21, 0), .init(22, 0), .init(23, 0), .init(32, 2), .init(100, 2),
    ]
    static let checkedOutput: Set<Proto.Key> = [
        .init(1, 0), .init(2, 0), .init(4, 0), .init(5, 0), .init(6, 0), .init(7, 0), .init(8, 0), .init(9, 0),
        .init(14, 0), .init(15, 0),
    ]

    /// What each output's entry in `metering` holds that the API reports too, on (1) or off (0).
    static let overlayFields: [(field: Int, overlay: MonitorOverlay)] = [
        (1, .lut), (2, .frameGuides), (4, .falseColor), (5, .zebra), (9, .cleanFeed),
    ]

    /// Why this preset can't be taken as laid out as Camera 10.3.1's, or nil when it can. A PYXIS on software Tiles
    /// hasn't checked has its presets used only then: `transport`, `metering` and an entry in `metering` for each output
    /// the API reports (`outputs`, in its order) hold every field 10.3.1's do, as the same kind of field; each entry's
    /// LUT, frame guides, false color, zebra and clean feed are what the API reports for that output (the entries are
    /// in the API's order, so this is what says they still are); and what Tiles reads is in range.
    func layoutMismatch(outputs: [(name: String, overlays: [MonitorOverlay: Bool])]) -> String? {
        guard let transport = section("transport").flatMap({ Proto.parse($0.settings) }) else { return "no transport section" }
        if let missing = Self.checkedTransport.subtracting(transport.map(\.key)).min() {
            return "transport has no field \(missing)"
        }
        let desqueeze = transport.first { $0.number == PresetSettings.desqueezeField }?.varint ?? 0
        guard desqueeze < PresetSettings.desqueezeFactors.count else { return "de-squeeze \(desqueeze)" }
        guard let metering = section("metering").flatMap({ Proto.parse($0.settings) }) else { return "no metering section" }
        if let missing = Self.checkedMetering.subtracting(metering.map(\.key)).min() {
            return "metering has no field \(missing)"
        }
        // The LUT in use: a file name, as the camera's LUTs are .cube files.
        let lut = metering.first { $0.number == PresetSettings.lutField }.map { String(decoding: $0.bytes, as: UTF8.self) } ?? ""
        guard lut.isEmpty || lut.lowercased().hasSuffix(".cube") else { return "its LUT field isn't a .cube file name" }
        let entries = metering.filter { $0.number == PresetSettings.outputs }
        guard entries.count == outputs.count else {
            return "\(entries.count) outputs in its monitoring, \(outputs.count) in the API"
        }
        for (entry, output) in zip(entries, outputs) {
            guard entry.wire == 2, let fields = Proto.parse(entry.bytes) else { return "\(output.name) isn't a message" }
            if let missing = Self.checkedOutput.subtracting(fields.map(\.key)).min() {
                return "\(output.name) has no field \(missing)"
            }
            func value(_ number: Int) -> UInt64 { fields.first { $0.number == number }?.varint ?? 0 }
            // Switches are 0 or 1; what status text shows, one of its four.
            if let number = ([PresetSettings.statusTextField] + Self.overlayFields.map(\.field)).first(where: { value($0) > 1 }) {
                return "\(output.name)'s field \(number) is \(value(number))"
            }
            guard value(PresetSettings.contentField) <= 4 else {
                return "\(output.name)'s field \(PresetSettings.contentField) is \(value(PresetSettings.contentField))"
            }
            for (number, overlay) in Self.overlayFields {
                guard let reported = output.overlays[overlay], value(number) != (reported ? 1 : 0) else { continue }
                return "\(output.name)'s \(overlay.title) is \(reported ? "on" : "off") in the API and not in the preset"
            }
        }
        return nil
    }

    mutating func setStatusText(_ on: Bool, output: Int) throws {
        try set("metering", [Proto.Step(field: PresetSettings.outputs, index: output), Proto.Step(field: PresetSettings.statusTextField)],
                to: on ? 1 : 0)
    }

    mutating func setStatusTextContent(_ content: StatusTextContent, output: Int) throws {
        guard let code = PresetSettings.contentCodes[content] else { throw PresetError.unexpected }
        try set("metering", [Proto.Step(field: PresetSettings.outputs, index: output), Proto.Step(field: PresetSettings.contentField)],
                to: code)
    }

    mutating func setLUT(_ name: String) throws {
        guard !name.isEmpty else { throw PresetError.unexpected }
        try set("metering", [Proto.Step(field: PresetSettings.lutField)], to: name)
    }

    mutating func setDesqueeze(_ factor: String) throws {
        guard let index = PresetSettings.desqueezeFactors.firstIndex(of: factor) else { throw PresetError.unexpected }
        try set("transport", [Proto.Step(field: PresetSettings.desqueezeField)], to: UInt64(index))
    }
}
