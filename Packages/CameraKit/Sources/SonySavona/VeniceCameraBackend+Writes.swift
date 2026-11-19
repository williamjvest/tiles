import CameraCore
import Foundation
import os

extension VeniceCameraBackend {
    // MARK: - Writes

    /// A setting: shown as pending, sent in the shape the camera's own values use (an EI that reads "800EI" writes
    /// "800EI"; one that reads 800 writes 800), confirmed by the camera's notification or a re-read.
    func write(_ raw: MPValue, for name: String, format: ((Double) -> MPValue)? = nil) async {
        let shaped: MPValue
        if let format, let number = raw.number {
            shaped = shapeValue(format(number), like: stored(name))
        } else if let number = raw.number, case .int = raw {
            shaped = shapeValue(.int(Int64(number)), like: stored(name))
        } else {
            shaped = shapeValue(raw, like: stored(name))
        }
        pending[name] = shaped
        pendingSince[name] = Date()
        do {
            if let slot = Self.slot(name) {
                try await client.set(slot.base, .map([slot.key: shaped]), timeout: 3)
            } else {
                try await client.set(name, shaped, timeout: 3)  // the page's own timeout; an ignored write mustn't hold the queue
            }
            settleLater([name])
        } catch {
            pending[name] = nil
            pendingSince[name] = nil
            log.error("set \(name, privacy: .public): \(String(describing: error).prefix(140), privacy: .public)")
        }
        rebuild()
    }

    /// A value asked for and not yet confirmed, while it's fresh: one the camera took without a word (a locked menu
    /// item answers and changes nothing) stops showing once `settleLater` has re-read it, and after 6 s regardless.
    func livePending(_ name: String) -> MPValue? {
        guard let value = pending[name], let since = pendingSince[name], Date().timeIntervalSince(since) < 6 else { return nil }
        return value
    }

    /// The camera confirms a change by notification. If one hasn't come 2.5 s after the write, re-read what was asked for
    /// and show what the camera has, so a write it accepted and ignored doesn't sit as pending.
    /// What the lists that change with the mode hang on: the imager mode, the recording format, the project rate and the
    /// base ISO. Select FPS's list is the camera's own, read at connect, and nothing says the camera announces a new one
    /// when these change; its own page asks for it again each time it opens it (captures/venice). A list read
    /// in 8.6K 17:9 (to 48) left up in 8.6K 3:2 (to 30) offers 48 in open gate, one way Tiles could send a rate the
    /// camera can't take.
    var listsFollow: Set<String> {
        Set([property[.imager], property[.codec], property[.baseISO], VeniceMenu.projectRateProperty].compactMap { $0 })
    }

    /// After a mode change: Select FPS from Sony's table for the new mode at once, then the camera's lists again once
    /// the change has settled (an imager mode restarts the image first). The menu's own lists of what's allowed now are
    /// read again too, each kept as it was if the camera doesn't answer.
    func relistLater() {
        if let name = property[.sqRate] { options[name] = nil }
        relistTask?.cancel()
        relistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.relist()
        }
    }

    func relist() async {
        guard state.connection == .connected else { return }
        if let name = property[.sqRate] {
            // Unanswered (the camera still restarting) is empty: Sony's table stays, which is right for the mode.
            let list = await client.options(for: Self.capabilityName(name), timeout: 3)
            options[name] = list.isEmpty ? nil : list
        }
        for name in [VeniceMenu.projectRateAllowed, VeniceMenu.recordingFormatAllowed, VeniceMenu.imagerModeAllowed] {
            let list = await client.options(for: name, timeout: 3)
            if !list.isEmpty { options[name] = list }
        }
        rebuild()
        yield()
    }

    func settleLater(_ names: [String]) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            await self?.settle(names)
        }
    }

    func settle(_ names: [String]) async {
        guard state.connection == .connected else { return }
        let stale = names.filter { name in
            if name == property[.assign] { return pendingKeys.values.contains { Date().timeIntervalSince($0.since) >= 2 } }
            return pendingSince[name].map { Date().timeIntervalSince($0) >= 2 } ?? false
        }
        guard !stale.isEmpty else { return }
        let bases = Array(Set(stale.map { Self.slot($0)?.base ?? $0 }))
        if let answered = try? await client.get(bases, timeout: 6) { values.merge(answered) { _, new in new } }
        // A write made to one of these while the read was out is its own, still waiting for its camera: leave it.
        for name in stale where pendingSince[name].map({ Date().timeIntervalSince($0) >= 2 }) ?? false {
            pending[name] = nil
            pendingSince[name] = nil
        }
        if stale.contains(where: { $0 == property[.assign] }) {
            pendingKeys = pendingKeys.filter { Date().timeIntervalSince($0.value.since) < 2 }
        }
        let names = stale.joined(separator: ", ")
        log.notice("unconfirmed after 2.5 s, re-read: \(names, privacy: .public)")
        rebuild()
        yield()
    }

    /// Several properties in one Property.SetValue, the way VENICE 2's page sends linked settings (shutter mode and
    /// its value; Kelvin, tint and type; S&Q's switch, rate and denominator; ND's mode and value). One alone can be
    /// ignored.
    func writeAll(_ props: [String: MPValue]) async {
        for (name, value) in props {
            pending[name] = value
            pendingSince[name] = Date()
        }
        do {
            _ = try await client.request("Property.SetValue", .array([.map(props)]), timeout: 3)
            settleLater(Array(props.keys))
        } catch {
            for name in props.keys {
                pending[name] = nil
                pendingSince[name] = nil
            }
            let names = props.keys.sorted().joined(separator: " + ")
            log.error("set \(names, privacy: .public): \(String(describing: error).prefix(140), privacy: .public)")
        }
        rebuild()
    }

    /// A VENICE doesn't put the EI on a new base: it goes where it was last on that base, or to the bottom of the new
    /// range (e.g. 2500 at base 800 read 800EI after the switch to 3200). Tiles'
    /// base switch puts the EI on the base, as Sony's other bodies do: once the camera has taken the base and listed the
    /// EIs that go with it, the EI is written. Nothing is written when the camera didn't take the base.
    func moveEIToBase(_ base: Int, high: Bool, baseProperty: String) async {
        guard let ei = property[.ei] else { return }
        func taken() -> Bool {
            guard let now = values[baseProperty] else { return false }
            if let text = now.unwrapped.string, text.uppercased().hasPrefix("ISO") {
                return Int(text.filter(\.isNumber)) == base
            }
            return (now.unwrapped.number ?? -1) == (high ? 1 : 0)
        }
        func listed() -> Bool {
            let list = options[ei] ?? []
            return list.isEmpty || list.contains { $0.number.map { Int($0) } == base }
        }
        let deadline = Date().addingTimeInterval(3)
        while !(taken() && listed()) {
            guard Date() < deadline, state.connection == .connected else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The camera's own EI after the switch has landed too (it notifies it with the base): then it's replaced.
        try? await Task.sleep(for: .milliseconds(150))
        guard (livePending(ei) ?? values[ei])?.unwrapped.number.map({ Int($0) }) != base else { return }
        await write(.int(Int64(base)), for: ei)
    }

    /// White balance as VENICE 2's page sends it: Kelvin, tint and type "User" together, as strings.
    func writeWhiteBalance(kelvin: Int?, tint: Int?) async {
        guard let kName = property[.kelvin] else { return }
        let tName = property[.tint]
        let currentK = values[kName]?.unwrapped.number.map { Int($0) } ?? 5600
        let currentT = tName.flatMap { values[$0]?.unwrapped.number }.map { Int($0) } ?? 0
        if values[kName]?.unwrapped.string != nil, let tName {
            var props: [String: MPValue] = [kName: .string(String(kelvin ?? currentK)),
                                            tName: .string(String(tint ?? currentT))]
            if kName.hasPrefix("Camera.WhiteBalance.ColorTemperature") {
                props["Camera.WhiteBalance.ColorTemperature.Type"] = .string("User")
            }
            await writeAll(props)
        } else {
            if let kelvin { await write(MPValue(kelvin), for: kName) }
            if let tint, let tName { await write(MPValue(tint), for: tName) }
        }
    }

    /// S&Q's rate as the page writes it: a whole number over a denominator (33.33 is 100 / 3).
    static func sqRateProps(_ rateName: String, _ rate: Double) -> [String: MPValue] {
        let thirds = abs(rate * 3 - (rate * 3).rounded()) < 0.05 && abs(rate - rate.rounded()) > 0.05
        let numerator = thirds ? Int64((rate * 3).rounded()) : Int64(rate.rounded())
        return [rateName: .int(numerator), rateName + ".Denominator": .int(thirds ? 3 : 1)]
    }

    /// VENICE 2 keeps every output's LUT in two maps, `Output.Video.SDI.LUT.Value` {"sdi1", "sdi3"} and
    /// `Output.Video.ViewFinder.LUT.Value` {"monitor", "hdmi", "vf"}, and takes a change as {key: name} (the page's
    /// LUTConverter.js, savona-2.9.4). Tiles names an output's LUT "base#key".
    static func slot(_ name: String) -> (base: String, key: String)? {
        guard let hash = name.firstIndex(of: "#") else { return nil }
        return (String(name[..<hash]), String(name[name.index(after: hash)...]))
    }

    /// A property's value, or one output's entry in a LUT map.
    func stored(_ name: String) -> MPValue? {
        guard let slot = Self.slot(name) else { return values[name] }
        return values[slot.base]?.map?[slot.key]
    }

    /// The capability list behind a LUT slot: Output.Video.SDI.LUT.Value.SDI1, ….ViewFinder.LUT.Value.Monitor.
    static func capabilityName(_ name: String) -> String {
        guard let slot = slot(name) else { return name }
        let key = ["sdi1": "SDI1", "sdi3": "SDI3", "monitor": "Monitor", "hdmi": "HDMI", "vf": "VF"][slot.key] ?? slot.key
        return slot.base + "." + key
    }

    static let lutBases = ["Output.Video.SDI.LUT.Value", "Output.Video.ViewFinder.LUT.Value"]

    /// The same meaning in the type the camera reads this property as: an int where it answers an int, "800EI" where
    /// it answers that.
    func shapeValue(_ value: MPValue, like seen: MPValue?) -> MPValue {
        guard let seen, !seen.isNull else { return value }
        switch (seen.unwrapped, value) {
        // VENICE 2's menu switches read and take "0" / "1" (P.System.Menu.MarkerVfOnoff, FalseColor, ColorBar…); a
        // bool gets no answer at all, which held the queue and looked like a dropped link (VENICE 2).
        case (.string(let word), .bool(let b)) where word == "0" || word == "1":
            return .string(b ? "1" : "0")
        case (.string, .int(let i)): return .string(stringForInt(i, like: seen))
        case (.int, .string(let s)): return .int(Int64(Double(s.filter { $0.isNumber || $0 == "." }) ?? 0))
        case (.int, .double(let d)): return .int(Int64(d))
        case (.double, .int(let i)): return .double(Double(i))
        case (.string(let word), .bool(let b)) where ["on", "off"].contains(word.lowercased()):
            return .string(b ? "On" : "Off")
        case (.string(let word), .bool(let b)) where ["enable", "disable"].contains(word.lowercased()):
            return .string(b ? "Enable" : "Disable")
        case (.map(let m), _) where m["cam"] != nil:
            return .map(["cam": shapeValue(value, like: m["cam"]!)])
        default: return value
        }
    }

    func stringForInt(_ i: Int64, like sample: MPValue) -> String {
        if let s = sample.unwrapped.string {
            if let digits = s.range(of: #"\d+"#, options: .regularExpression) {
                return s.replacingCharacters(in: digits, with: String(i))
            }
        }
        return String(i)
    }

    func press(_ name: String) async {
        _ = try? await client.set(name, .bool(true))
        try? await Task.sleep(for: .milliseconds(400))
        _ = try? await client.set(name, .bool(false))
    }

    func sendKey(_ key: String) async {
        do { try await client.sendKey(key) } catch { log.error("key \(key, privacy: .public) failed") }
    }

    /// A Camera Menu key (`menuKeys`), as `Button.SendKeys` sends REC. One at a time, with the camera page's 3 s: a key
    /// the camera doesn't answer holds every request behind it until then, so a tap while one is out is dropped, and a key
    /// it doesn't answer or turns down comes off the Camera Menu for this connection (its name is all that's unproven).
    func pressMenuKey(_ button: CameraBodyButton) async {
        guard let key = Self.menuKeys[button], !unansweredKeys.contains(key) else { return }
        guard !menuKeyInFlight else {
            log.notice("key \(key, privacy: .public) dropped: the last one is still out")
            return
        }
        menuKeyInFlight = true
        defer { menuKeyInFlight = false }
        do {
            try await client.sendKey(key, timeout: 3)
        } catch let error as SavonaClient.SavonaError where Self.notTaken(error) {
            unansweredKeys.insert(key)
            log.error("key \(key, privacy: .public): \(String(describing: error).prefix(120), privacy: .public); off the Camera Menu")
            ActivityLog.shared.note(host, "VENICE didn't take the \(key) key (\(String(describing: error).prefix(80))): off the Camera Menu until it reconnects")
            rebuild()
            yield()
        } catch {
            log.error("key \(key, privacy: .public) failed: \(String(describing: error).prefix(120), privacy: .public)")
        }
    }

    /// A key the camera timed out on or turned down, as opposed to one that never left (`isTransportFailure`).
    static func notTaken(_ error: SavonaClient.SavonaError) -> Bool {
        switch error {
        case .timeout: true
        case .refused: !isTransportFailure(error)
        default: false
        }
    }

    /// A request that never reached the camera (the socket's own failure), as against one the camera answered no.
    static func isTransportFailure(_ error: SavonaClient.SavonaError) -> Bool {
        if case .refused(let why) = error { return why.hasPrefix("send:") }
        return false
    }

    /// What frame line set A or B shows of the user frame lines: both switches the camera page writes, in one request
    /// as the page sends linked settings, but only the ones that change (one the camera already has wouldn't be
    /// reported back, and would read as unconfirmed).
    func setUserFrameLines(_ set: FrameLineSet, _ label: String) async {
        guard let boxes = UserFrameLines.boxes(label) else { return }
        let names = set == .a ? Self.userFrameA : Self.userFrameB
        var props: [String: MPValue] = [:]
        for (name, on) in [(names.first, boxes.first), (names.second, boxes.second)] {
            guard let now = (livePending(name) ?? values[name])?.unwrapped.string else { continue }  // not on this camera
            let wanted = on ? "1" : "0"
            if now != wanted { props[name] = .string(wanted) }
        }
        guard !props.isEmpty else { return }
        await writeAll(props)
    }
}
