import Foundation

// The ARRI Web Remote's HTTP interface (ALEXA Mini, Mini LF, ALEXA 35, AMIRA), as the cameras serve it to their own
// browser page (docs/arri.md). Read from how public tools drive it, not from an ARRI document: there is none.
//
//   GET  /all.cgi            {"id": S, "variables": {name: {value, type, min, max, readonly, properties}},
//                             "commands": {id: name}}
//                            S is a CLIENT SESSION id, not a change counter. The camera opens a new session for each
//                            all.cgi call; subsequent update.cgi polls must reuse the same S.
//   GET  /update.cgi?id=S    long poll: blocks ~3 s then answers {id: S, variables: {name: {value, …changed fields}}}
//                            with only what changed since the session's last answer. S is echoed unchanged.
//                            ERROR {"ERROR": "…Invalid id…"} means the session is gone: call all.cgi again.
//   GET  /js/all-dg.min.js   the page's own script: each enum's order and English labels
//   POST /set.cgi            {name: value} → {"result": 1}
//   POST /call.cgi           {"command": id, "set": {…}} → {"result": n ≥ 0}
//
// Enums travel as indexes into the page script's lists; the labels come from the camera, never from a table here
// (a Mini LF's TWO_POINT_ONE ND token reads "ND 1.8").

/// A value as the Web Remote's JSON carries it.
public enum ArriValue: Sendable, Equatable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null
    /// Anything else (a list, an object): its JSON text, shown but never written.
    case other(String)

    public init(json: Any?) {
        switch json {
        case nil:
            self = .null
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String:
            self = .string(text)
        case let other?:
            if JSONSerialization.isValidJSONObject(other),
               let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) {
                self = .other(String(decoding: data, as: UTF8.self))
            } else {
                self = .other(String(describing: other))
            }
        }
    }

    /// For a request body: a whole number goes as an integer, as the page sends enum indexes. A number JSON can't carry
    /// (NaN, infinity) goes as null rather than crashing the encoder.
    public var json: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n) where !n.isFinite: return NSNull()
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): return s
        case .null: return NSNull()
        case .other(let s): return s
        }
    }

    public var number: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "on", "1", "yes", "enabled": return true
            case "false", "off", "0", "no", "disabled": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): return "\"\(s)\""
        case .null: return "null"
        case .other(let s): return s
        }
    }

    /// Parses a command-line value: true/false, a number, else text.
    public static func parse(_ text: String) -> ArriValue {
        if text == "true" || text == "false" { return .bool(text == "true") }
        if let n = Double(text) { return .number(n) }
        if text == "null" { return .null }
        return .string(text)
    }
}

/// One of the camera's variables, with what `all.cgi` says about it.
public struct ArriVariable: Sendable, Equatable {
    public var value: ArriValue
    /// "float", "int", "long", "bool", "enumint", "string", … as the camera names it.
    public var type: String?
    public var min: Double?
    public var max: Double?
    public var readOnly: Bool
    /// Per enum index, the camera's flags: `& 3 == 3` is a choice that can be picked now. Nil when it doesn't say.
    public var flags: [Int]?

    public init(value: ArriValue, type: String? = nil, min: Double? = nil, max: Double? = nil, readOnly: Bool = false,
                flags: [Int]? = nil) {
        self.value = value
        self.type = type
        self.min = min
        self.max = max
        self.readOnly = readOnly
        self.flags = flags
    }

    init(json: [String: Any]) {
        value = ArriValue(json: json["value"])
        type = json["type"] as? String
        min = (json["min"] as? NSNumber)?.doubleValue
        max = (json["max"] as? NSNumber)?.doubleValue
        readOnly = ArriValue(json: json["readonly"]).bool ?? false
        flags = (json["properties"] as? [Any])?.map { ($0 as? NSNumber)?.intValue ?? 0 }
    }

    /// Updates from an `update.cgi` entry: the fields it carries replace these, the rest stay.
    mutating func merge(_ json: [String: Any]) {
        if json.keys.contains("value") { value = ArriValue(json: json["value"]) }
        if let t = json["type"] as? String { type = t }
        if let n = json["min"] as? NSNumber { min = n.doubleValue }
        if let n = json["max"] as? NSNumber { max = n.doubleValue }
        if json.keys.contains("readonly") { readOnly = ArriValue(json: json["readonly"]).bool ?? readOnly }
        if let list = json["properties"] as? [Any] { flags = list.map { ($0 as? NSNumber)?.intValue ?? 0 } }
    }

    public var isEnum: Bool { type?.lowercased().hasPrefix("enum") == true }
    public var isBool: Bool { type?.lowercased() == "bool" || (type == nil && { if case .bool = value { return true }; return false }()) }

    /// Whether enum choice `index` can be picked now: inside min…max, and flagged selectable where flags are given.
    public func selectable(_ index: Int) -> Bool {
        if let min, Double(index) < min { return false }
        if let max, Double(index) > max { return false }
        guard let flags else { return true }
        return flags.indices.contains(index) && flags[index] & 3 == 3
    }

    /// The enum indexes the camera reports, in order: its flags' length, else min…max.
    public var enumIndexes: [Int] {
        if let flags { return Array(flags.indices) }
        if let low = min?.asInt, let high = max?.asInt, high >= low, high - low < 2000 { return Array(low...high) }
        return []
    }
}

/// Everything `all.cgi` answered: the session id and all variables and commands.
public struct ArriSnapshot: Sendable, Equatable {
    /// The session id returned by `all.cgi`. `update.cgi?id=` passes this same value back; the camera echoes it in
    /// each answer. It is not a change counter — the same value is reused for the lifetime of the session.
    public var id: Int
    public var variables: [String: ArriVariable]
    /// Command ID → name. Several IDs can share a name (PlayBackSkipClip back and forward).
    public var commands: [String: String]

    public init(id: Int = 0, variables: [String: ArriVariable] = [:], commands: [String: String] = [:]) {
        self.id = id
        self.variables = variables
        self.commands = commands
    }

    public init(data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArriError.badResponse("all.cgi: not a JSON object")
        }
        try self.init(json: json)
    }

    public init(json: [String: Any]) throws {
        if let message = json["ERROR"] as? String ?? json["error"] as? String { throw ArriError.camera(message) }
        guard let raw = json["variables"] as? [String: Any] else { throw ArriError.badResponse("all.cgi: no variables") }
        id = (json["id"] as? NSNumber)?.intValue ?? 0
        var variables: [String: ArriVariable] = [:]
        for (name, entry) in raw {
            if let fields = entry as? [String: Any] {
                variables[name] = ArriVariable(json: fields)
            } else {
                variables[name] = ArriVariable(value: ArriValue(json: entry))
            }
        }
        self.variables = variables
        commands = (json["commands"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }

    /// Folds in an `update.cgi` answer and returns the names that changed — either their value, or any field metadata
    /// (min, max, readonly, properties). Takes `{"id", "variables": {name: {value…}}}`, `{"id", "variables": {name:
    /// value}}`, or the changes at the top level beside `id`: which one the cameras send is a first-session question,
    /// so all three are read.
    @discardableResult
    public mutating func merge(update json: [String: Any]) -> [String] {
        if let n = json["id"] as? NSNumber { id = n.intValue }
        var changed: [String] = []
        func take(_ name: String, _ entry: Any) {
            let before = variables[name]
            if let fields = entry as? [String: Any] {
                if variables[name] == nil {
                    variables[name] = ArriVariable(json: fields)
                } else {
                    variables[name]!.merge(fields)
                }
            } else {
                if variables[name] == nil {
                    variables[name] = ArriVariable(value: ArriValue(json: entry))
                } else {
                    variables[name]!.value = ArriValue(json: entry)
                }
            }
            // Track any change: value, range, or readonly flag.
            if variables[name] != before { changed.append(name) }
        }
        if let raw = json["variables"] as? [String: Any] {
            for (name, entry) in raw { take(name, entry) }
        } else {
            // Beside the id, only names the camera already has: anything else there is the answer's own bookkeeping.
            for (name, entry) in json where variables[name] != nil { take(name, entry) }
        }
        if let raw = json["commands"] as? [String: Any] {
            for (id, name) in raw { if let name = name as? String { commands[id] = name } }
        }
        return changed.sorted()
    }

    /// The IDs that run the command `name`, in a stable order (by ID).
    public func commandIDs(named name: String) -> [String] {
        commands.filter { $0.value == name }.map(\.key).sorted()
    }
}

extension Double {
    /// A whole number from a camera's value, nil where `Int(_:)` would trap or the value isn't one (NaN, ±∞, beyond
    /// ±10¹²).
    public var asInt: Int? {
        guard isFinite, abs(self) < 1e12 else { return nil }
        return Int(self.rounded(.towardZero))
    }
}

/// What went wrong talking to the camera.
public enum ArriError: Error, Sendable, CustomStringConvertible, Equatable {
    case badAddress(String)
    case http(Int)
    case badResponse(String)
    /// The camera's own `{"ERROR": …}`.
    case camera(String)
    /// `set.cgi` or `call.cgi` answered without accepting.
    case refused(String)
    case readOnly(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .badAddress(let a): "not an address: \(a)"
        case .http(let code): "HTTP \(code)"
        case .badResponse(let why): "unexpected answer (\(why))"
        case .camera(let message): "camera: \(message)"
        case .refused(let why): "refused: \(why)"
        case .readOnly(let name): "\(name) is read-only now"
        case .unavailable(let name): "\(name) isn't on this camera"
        }
    }
}

// MARK: - The page script's enums

/// Each enum's order and English labels, read from the Web Remote page's own script (`/js/all-dg.min.js`). It
/// declares a variable's enum type (`X.ExposureIndex={…type:"ExposureIndex"…}`), the type's tokens in index order
/// (`ExposureIndex:"EI_160 EI_200 …".split(" ")` or `NDFilter:["CLEAR",…]`), and each token's label
/// (`….en.ENUM_NDFilter_TWO_POINT_ONE="ND 1.8"`).
public struct ArriEnumCatalog: Sendable, Equatable {
    /// Variable → enum type.
    public var typeOfVariable: [String: String]
    /// Enum type → tokens in index order.
    public var tokens: [String: [String]]
    /// "Type_TOKEN" → English label.
    public var labels: [String: String]

    public init(typeOfVariable: [String: String] = [:], tokens: [String: [String]] = [:], labels: [String: String] = [:]) {
        self.typeOfVariable = typeOfVariable
        self.tokens = tokens
        self.labels = labels
    }

    public var isEmpty: Bool { tokens.isEmpty }

    public init(javascript source: String) {
        let ns = source as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern))?.matches(in: source, range: whole) ?? []
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }

        // Declarations: an object literal with a type, assigned to the variable's name.
        var types: [String: String] = [:]
        for match in matches(#"\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{([^{}]{0,600})\}"#) {
            guard let key = group(match, 1), let body = group(match, 2),
                  let type = Self.firstGroup(#"\btype\s*:\s*["']([A-Za-z0-9_]+)["']"#, in: body) else { continue }
            let name = Self.firstGroup(#"\bname\s*:\s*["']([A-Za-z0-9_]+)["']"#, in: body) ?? key
            types[name] = type
        }

        // Token lists, both spellings. The page's dependency lists are keyed by variable names too, in the split
        // spelling: an ALEXA Mini's script has `GuiMode:"_aiYR0… _IyoSk…".split(" ")` besides the enum's own list
        // (and so for ten other enums). Page-model ids, not tokens: passed over.
        var lists: [String: [String]] = [:]
        for match in matches(#"([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*["']([^"']*)["']\s*\.split\(\s*["'] ["']\s*\)"#) {
            guard let type = group(match, 1), let text = group(match, 2), lists[type] == nil else { continue }
            let items = text.split(separator: " ").map(String.init)
            if !items.isEmpty, !items.allSatisfy(Self.isModelID) { lists[type] = items }
        }
        for match in matches(#"([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*\[\s*((?:"[^"\\]*"|'[^'\\]*')(?:\s*,\s*(?:"[^"\\]*"|'[^'\\]*'))*)\s*,?\s*\]"#) {
            guard let type = group(match, 1), let body = group(match, 2), lists[type] == nil else { continue }
            let items = Self.allGroups(#"["']([^"']*)["']"#, in: body)
            if !items.isEmpty, !items.allSatisfy(Self.isModelID) { lists[type] = items }
        }
        // Keep the lists some variable uses (a big script has many unrelated arrays).
        let used = Set(types.values)
        let kept = lists.filter { used.contains($0.key) }
        tokens = kept
        typeOfVariable = types.filter { kept[$0.value] != nil }

        // English labels: `.en.ENUM_T_K="…"` first; failing that any `ENUM_T_K` key, the first seen winning.
        var found: [String: String] = [:]
        for match in matches(#"\.en\.ENUM_([A-Za-z0-9_]+)\s*=\s*"((?:[^"\\]|\\.)*)""#) {
            guard let key = group(match, 1), let raw = group(match, 2), found[key] == nil else { continue }
            found[key] = Self.unescape(raw)
        }
        if found.isEmpty {
            for match in matches(#"["']?ENUM_([A-Za-z0-9_]+)["']?\s*[:=]\s*"((?:[^"\\]|\\.)*)""#) {
                guard let key = group(match, 1), let raw = group(match, 2), found[key] == nil else { continue }
                found[key] = Self.unescape(raw)
            }
        }
        labels = found
    }

    /// The tokens behind a variable's indexes, nil when the script doesn't declare it.
    public func tokens(forVariable name: String) -> [String]? {
        typeOfVariable[name].flatMap { tokens[$0] }
    }

    public func token(variable name: String, index: Int) -> String? {
        guard let list = tokens(forVariable: name), list.indices.contains(index) else { return nil }
        return list[index]
    }

    /// The English label for a variable's index: the script's own, else the token made readable ("ZERO_POINT_SIX" →
    /// "Zero Point Six"). Nil for a variable the script doesn't declare.
    public func label(variable name: String, index: Int) -> String? {
        guard let type = typeOfVariable[name], let token = token(variable: name, index: index) else { return nil }
        if let label = labels["\(type)_\(token)"] { return label }
        return Self.readable(token)
    }

    /// A page-model id, e.g. "_aiYR0OjXEeSdT43XlOyQBg": what the page's commands, conditions and dependency lists are
    /// named by. No enum token looks like one.
    static func isModelID(_ item: String) -> Bool {
        item.hasPrefix("_") && item.count >= 20
            && item.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    static func readable(_ token: String) -> String {
        token.split(separator: "_").map { word in
            word.contains(where: \.isNumber) || acronyms.contains(word.uppercased()) ? word.uppercased()
                : word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Kept in capitals when a token is spelled out.
    static let acronyms: Set<String> = ["HD", "UHD", "ND", "EVF", "SDI", "MON", "LUT", "LF", "OG", "WB", "AWB", "CC",
                                        "TC", "ISO", "EI", "REC", "RAW", "HQ", "LT", "XQ", "ALF", "CDL", "ARRI",
                                        "ARRIRAW", "MXF", "HDMI", "VF", "FPS", "S35", "S16"]

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        allGroups(pattern, in: text).first
    }

    static func allGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// A JavaScript string literal's escapes: \" \\ \n \t \uXXXX.
    static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = ""
        var chars = raw.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let next = chars.next() else { out.append(c); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = chars.next() { hex.append(h) } }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            default: out.append(next)
            }
        }
        return out
    }
}
