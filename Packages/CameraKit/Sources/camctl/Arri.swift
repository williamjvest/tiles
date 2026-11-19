// camctl arri: an ARRI camera's Web Remote through the app's own backend (against a camera, scripts/arri/mock_alexa.py,
// or a capture directory written by scripts/arri/arri.py).

import ArriWebRemote
import CameraCore
import Foundation

@MainActor
enum ArriCLI {
    static let usage = """
        camctl arri HOST [--dump] [--get NAME]… [--set NAME=VALUE]… [--call COMMAND [JSON]]… [--listen SECS]
        camctl arri --from DIR [--dump]     what Tiles reads from a capture (DIR/all.cgi.json + DIR/all-dg.min.js)
        camctl arri HOST [--rec SECS] [--resolution LABEL] [--codec LABEL] [--play] [--selftest] [--wait SECS]
                         [--follow SECS]    the app's backend held open, steps run through it in order and timed,
                                            every change it would show printed as it comes
        """

    static func run(_ args: ArraySlice<String>) async {
        var host: String?
        var from: String?
        var gets: [String] = []
        var sets: [String] = []
        var calls: [(String, String)] = []
        var dump = false
        var listen: Double = 0
        var steps: [ArriSession.Step] = []
        var follow: Double = 0
        var it = Array(args).makeIterator()
        var pendingCall: String?
        func flushCall(_ json: String = "{}") {
            if let name = pendingCall { calls.append((name, json)); pendingCall = nil }
        }
        while let arg = it.next() {
            switch arg {
            case "--from": flushCall(); from = it.next()
            case "--get": flushCall(); gets.append(it.next() ?? "")
            case "--set": flushCall(); sets.append(it.next() ?? "")
            case "--call": flushCall(); pendingCall = it.next()
            case "--dump": flushCall(); dump = true
            case "--listen": flushCall(); listen = Double(it.next() ?? "10") ?? 10
            case "--rec": flushCall(); steps.append(.rec(Double(it.next() ?? "5") ?? 5))
            case "--resolution": flushCall(); steps.append(.resolution(it.next() ?? ""))
            case "--codec": flushCall(); steps.append(.codec(it.next() ?? ""))
            case "--play": flushCall(); steps.append(.play)
            case "--selftest": flushCall(); steps.append(.selftest)
            case "--wait": flushCall(); steps.append(.wait(Double(it.next() ?? "5") ?? 5))
            case "--follow": flushCall(); follow = Double(it.next() ?? "20") ?? 20
            default:
                if pendingCall != nil, arg.hasPrefix("{") { flushCall(arg) } else { flushCall(); if host == nil { host = arg } }
            }
        }
        flushCall()

        if let from {
            replay(directory: from, dump: dump)
            exit(0)
        }
        guard let host else { print(usage); exit(2) }
        if !steps.isEmpty || follow > 0 {
            await ArriSession.run(host: host, steps: steps, follow: follow)
            exit(0)
        }

        let backend = ArriCameraBackend(host: host)
        let connecting = Task { await backend.connect() }
        var connected = CameraState()
        for await state in backend.updates {
            if state.connection == .connected { connected = state; break }
            if case .failed(let why) = state.connection {
                print("connect failed: \(why)")
                connecting.cancel()
                exit(1)
            }
        }
        defer { connecting.cancel() }
        let reading = await backend.currentReading
        show(connected)
        if dump, let reading { printDump(reading) }
        let client = backend.client
        for name in gets {
            let variable = reading?.snapshot.variables[name]
            let label = variable.flatMap { v in v.isEnum ? v.value.number.flatMap { reading?.catalog.label(variable: name, index: Int($0)) } : nil }
            print("\(name) = \(variable?.value.description ?? "absent")\(label.map { "  (\($0))" } ?? "")")
        }
        for pair in sets {
            let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { continue }
            guard !MediaSafety.refuses(pair) else { print(MediaSafety.refusal(pair)); continue }
            do {
                try await client?.set([bits[0]: ArriValue.parse(bits[1])])
                print("set \(bits[0]) = \(bits[1]): accepted")
            } catch {
                print("set \(bits[0]) = \(bits[1]): \(error)")
            }
        }
        for (command, json) in calls {
            guard !MediaSafety.refuses(command + " " + json) else { print(MediaSafety.refusal(command + " " + json)); continue }
            let id = reading?.snapshot.commands[command] != nil ? command : reading?.snapshot.commandIDs(named: command).first
            guard let id else { print("no command \(command) (ids: \(reading?.snapshot.commands.values.sorted().joined(separator: ", ") ?? ""))"); continue }
            let values = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
                .mapValues { ArriValue(json: $0) }
            do {
                let result = try await client?.call(id, set: values)
                print("call \(command) [\(id)] → \(result.map(String.init) ?? "?")")
            } catch {
                print("call \(command) [\(id)]: \(error)")
            }
        }
        if listen > 0, let client, var id = reading?.snapshot.id {
            print("listening \(Int(listen))s on update.cgi…")
            let deadline = Date().addingTimeInterval(listen)
            while Date() < deadline {
                do {
                    guard let data = try await client.update(after: id, timeout: min(30, deadline.timeIntervalSinceNow + 1)) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    print("\(Self.clock()) \(text.prefix(600))")
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let next = (json["id"] as? NSNumber)?.intValue, next != id {
                        id = next
                    } else {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                } catch {
                    print("update.cgi: \(error)")
                    break
                }
            }
        }
        await backend.disconnect()
        let bytes = await backend.bytesRead
        print("read \(bytes) bytes")
        exit(0)
    }

    /// A capture's all.cgi and page script, read as the app would read them.
    static func replay(directory: String, dump: Bool) {
        let dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("all.cgi.json")),
              let snapshot = try? ArriSnapshot(data: data) else {
            print("no readable all.cgi.json in \(dir.path)")
            exit(1)
        }
        let script = (try? String(contentsOf: dir.appendingPathComponent("all-dg.min.js"), encoding: .utf8)) ?? ""
        var catalog = ArriEnumCatalog(javascript: script)
        if catalog.isEmpty { catalog = .fallback(for: snapshot, model: nil) }
        let reading = ArriReading(snapshot: snapshot, catalog: catalog)
        var state = CameraState()
        state.connection = .connected
        reading.apply(to: &state, host: "camera")
        show(state)
        printCoverage(reading)
        if dump { printDump(reading) }
    }

    static func show(_ s: CameraState) {
        func line(_ label: String, _ value: Any?) { print("  \(label): \(value.map { "\($0)" } ?? "—")") }
        print("Tiles reads it as:")
        line("model", s.model)
        line("REC", s.recording.state)
        line("timecode", s.timecode?.string(at: Date()))
        line("clip", s.clipName)
        line("EI", s.iso.map { "\($0.value) (\($0.options.count) options\($0.isWritable ? "" : ", read-only"))" })
        line("ND", s.nd.map { "\($0.preset.value) of \($0.preset.options.joined(separator: "/"))" })
        line("WB", s.whiteBalance.map { "\(Int($0.kelvin.value))K CC \($0.tint.map { String($0.value) } ?? "—")" })
        line("shutter", s.shutterAngle.map { "\($0.value)° = \(s.shutterSpeed?.value ?? "—"), mode \(s.shutterMode?.value.rawValue ?? "—")" })
        line("sensor fps", s.frameRate.map { "\($0.project.value) (\($0.project.options.first ?? "")–\($0.project.options.last ?? ""))" })
        line("sensor mode", s.resolution?.value)
        line("codec", s.fileFormat?.value)
        line("look", s.lut.map { "\($0.value) of \($0.options.count)" })
        line("outputs", s.monitoring?.outputs.map { o in
            "\(o.name)[" + o.overlays.keys.map(\.rawValue).sorted().map { "\($0)\(o.overlays[MonitorOverlay(rawValue: $0)!]!.value ? "+" : "-")" }
                .joined(separator: ",") + "]"
        }.joined(separator: " "))
        line("iris", s.iris?.value)
        line("de-squeeze", s.desqueeze?.value)
        line("colour bars", s.colorBars?.value)
        line("letter / reel", "\(s.fileNaming?.cameraID?.value ?? "—") / \(s.fileNaming?.reel.map { String(Int($0.value)) } ?? "—")")
        line("battery / media", "\(s.batteryPercent.map { "\($0)%" } ?? "—") / \(s.mediaRemainingMinutes.map { "\($0) min" } ?? "—")")
        line("playback", s.playback.map { "in review \($0.inReview.map(String.init) ?? "?"), playing \($0.isPlaying.map(String.init) ?? "?"), clips \($0.clipCount ?? 0)" })
        line("web remote", s.webRemoteURL)
    }

    /// Which variable each control came from: by name, by words (a guess to confirm), or none.
    static func printCoverage(_ reading: ArriReading) {
        print("Controls:")
        for field in ArriField.allCases {
            let how = reading.fields[field].map { name in field.candidates.contains(name) ? name : "\(name)   ← by words, confirm" }
            print("  \(field.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(how ?? "—")")
        }
        print("Outputs:")
        for output in reading.outputs {
            print("  \(output.name): " + output.switches.map { "\($0.key.rawValue)=\($0.value.variable)" }.sorted().joined(separator: " "))
        }
    }

    static func printDump(_ reading: ArriReading) {
        let snapshot = reading.snapshot
        print("\(snapshot.variables.count) variables (id \(snapshot.id)):")
        for name in snapshot.variables.keys.sorted() {
            let v = snapshot.variables[name]!
            var text = "\(name) = \(v.value)"
            if v.isEnum, let index = v.value.number.map({ Int($0) }) {
                text += "  [\(reading.catalog.label(variable: name, index: index) ?? "?")]"
                let labels = v.enumIndexes.map { i in (reading.catalog.label(variable: name, index: i) ?? "#\(i)") + (v.selectable(i) ? "" : "×") }
                text += "  of " + labels.prefix(30).joined(separator: " | ")
            }
            if let lo = v.min, let hi = v.max, !v.isEnum { text += "  \(ArriFormat.number(lo))…\(ArriFormat.number(hi))" }
            text += "  \(v.type ?? "?")\(v.readOnly ? " ro" : "")"
            print("  " + text)
        }
        print("\(snapshot.commands.count) commands:")
        for (id, name) in snapshot.commands.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            print("  \(name)  \(id)")
        }
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
