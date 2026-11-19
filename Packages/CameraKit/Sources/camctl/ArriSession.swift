// camctl arri HOST [--rec SECS] [--resolution LABEL] [--codec LABEL] [--play] [--selftest] [--wait SECS] [--follow SECS]
//
// The app's own ARRI backend held open against a camera: every change Tiles would show is printed as it arrives, with
// the time since the start, and the steps run through the backend in the order given, each timed. A step that changes
// a setting puts it back. A sensor format or codec change reloads the camera's software; the session reconnects as
// the app's controller would.

import ArriWebRemote
import CameraCore
import Foundation

@MainActor
enum ArriSession {
    enum Step {
        case rec(Double), resolution(String), codec(String), play, selftest, wait(Double)
    }

    /// The latest state, shared with the task that reads the backend's updates.
    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = CameraState()
        var state: CameraState { lock.withLock { value } }
        func set(_ s: CameraState) { lock.withLock { value = s } }
    }

    nonisolated static let start = Date()

    nonisolated static func clock() -> String { String(format: "%7.2f", Date().timeIntervalSince(start)) }

    static func run(host: String, steps: [Step], follow: Double) async {
        let backend = ArriCameraBackend(host: host)
        let latest = Latest()
        let watcher = Task.detached {
            var last: [String: String] = [:]
            for await s in backend.updates {
                latest.set(s)
                for (key, text) in summary(s).sorted(by: { $0.key < $1.key }) where last[key] != text {
                    last[key] = text
                    print("\(clock()) \(key): \(text)")
                }
            }
        }
        guard await connect(backend, latest) else {
            print("\(clock()) couldn't connect")
            watcher.cancel()
            return
        }
        for step in steps { await perform(step, backend, latest) }
        if follow > 0 { try? await Task.sleep(for: .seconds(follow)) }
        await backend.disconnect()
        watcher.cancel()
        print("\(clock()) done; read \(await backend.bytesRead) bytes")
    }

    /// What a tile would show, by topic: a line is printed whenever one of these changes.
    nonisolated static func summary(_ s: CameraState) -> [String: String] {
        var out: [String: String] = ["link": "\(s.connection)"]
        out["REC"] = "\(s.recording.state)" + (s.recording.state == .recording ? " (TC \(s.timecode?.string(at: Date()) ?? "—"))" : "")
        out["format"] = [s.resolution?.value, s.fileFormat?.value,
                         s.frameRate.map { "\($0.project.value) fps (\($0.project.options.first ?? "")–\($0.project.options.last ?? ""))" }]
            .compactMap { $0 }.joined(separator: " · ")
        out["exposure"] = [s.iso.map { "EI \($0.value)" }, s.nd.map { "ND \($0.preset.value)" },
                           s.whiteBalance.map { "\(Int($0.kelvin.value))K CC \($0.tint.map { String($0.value) } ?? "—")" },
                           s.shutterAngle.map { "\($0.value)°" + ($0.isWritable ? "" : " (locked)") },
                           s.frameRate.map { $0.project.isWritable ? "" : "fps locked" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if let p = s.playback {
            out["playback"] = "review \(p.inReview.map(String.init) ?? "?"), playing \(p.isPlaying.map(String.init) ?? "?"), "
                + "clip \(p.clipNumber.map(String.init) ?? "—") of \(p.clipCount.map(String.init) ?? "—")"
        }
        out["media"] = s.mediaRemainingMinutes.map { "\($0) min left" } ?? "—"
        // The clock object itself: a line each time it's anchored afresh (frames at the anchor, anchor time, running).
        out["clock"] = s.timecode.map { c in
            let at = String(format: "%.2f", c.anchor.timeIntervalSince(start))
            return "\(TimecodeClock(frames: c.frames, anchor: c.anchor, rate: c.rate, fps: c.fps, isRunning: false).string(at: c.anchor)) anchored at \(at)\(c.isRunning ? ", running" : ", still")"
        } ?? "—"
        return out
    }

    static func connect(_ backend: ArriCameraBackend, _ latest: Latest) async -> Bool {
        await backend.connect()
        return await until(10, latest) { $0.connection == .connected } != nil
    }

    /// Seconds from `t0` (the ask) until `condition` holds, or nil after `timeout`. Timed from the ask, since some sends
    /// (REC) return only once the camera has confirmed.
    static func until(_ timeout: Double, from t0: Date = Date(), _ latest: Latest,
                      _ condition: (CameraState) -> Bool) async -> Double? {
        while Date().timeIntervalSince(t0) < timeout {
            if condition(latest.state) { return Date().timeIntervalSince(t0) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    static func say(_ text: String) { print("\(clock()) ▸ \(text)") }

    static func took(_ t: Double?) -> String { t.map { String(format: "%.2f s", $0) } ?? "not within the wait" }

    static func perform(_ step: Step, _ backend: ArriCameraBackend, _ latest: Latest) async {
        switch step {
        case .wait(let seconds):
            try? await Task.sleep(for: .seconds(seconds))
        case .rec(let seconds):
            guard latest.state.recording.state != .recording else { return say("REC: already rolling, left alone") }
            say("REC start")
            var t0 = Date()
            await backend.send(.record(true))
            say("REC shown rolling after \(took(await until(10, from: t0, latest) { $0.recording.state == .recording }))")
            try? await Task.sleep(for: .seconds(seconds))
            say("REC stop")
            t0 = Date()
            await backend.send(.record(false))
            say("REC shown stopped after \(took(await until(10, from: t0, latest) { $0.recording.state == .idle }))")
        case .resolution(let label):
            await reloading("resolution \(label)", backend, latest, send: .setResolution(label), field: .sensorMode, label: label)
        case .codec(let label):
            await reloading("codec \(label)", backend, latest, send: .setFileFormat(label), field: .codec, label: label)
        case .play:
            say("review")
            var t0 = Date()
            await backend.send(.playback(.review))
            say("in review after \(took(await until(8, from: t0, latest) { $0.playback?.inReview == true }))")
            t0 = Date()
            await backend.send(.playback(.play))
            say("playing after \(took(await until(5, from: t0, latest) { $0.playback?.isPlaying == true }))")
            try? await Task.sleep(for: .seconds(2))
            t0 = Date()
            await backend.send(.playback(.pause))
            say("paused after \(took(await until(5, from: t0, latest) { $0.playback?.isPlaying == false }))")
            await backend.send(.playback(.previous))
            try? await Task.sleep(for: .seconds(1.5))
            t0 = Date()
            await backend.send(.playback(.live))
            say("live after \(took(await until(8, from: t0, latest) { $0.playback?.inReview == false }))")
        case .selftest:
            await selftest(backend, latest)
        }
    }

    /// A change that may reload the camera: sent, then the camera's own reading watched (the tile shows the choice at
    /// once, as pending) until it reports the value with no reload under way, through any reconnect.
    static func reloading(_ what: String, _ backend: ArriCameraBackend, _ latest: Latest, send: CameraCommand,
                          field: ArriField, label: String) async {
        if await backend.currentReading?.text(field) == label { return say("\(what): already") }
        say("\(what): asked")
        await backend.send(send)
        let t0 = Date()
        var stale: Double?
        while Date().timeIntervalSince(t0) < 90 {
            let s = latest.state
            if s.connection == .stale, stale == nil { stale = Date().timeIntervalSince(t0) }
            if case .failed = s.connection { await backend.connect() }
            if s.connection == .connected, let r = await backend.currentReading, r.text(field) == label,
               r.snapshot.variables["SystemSoftwareIsRestarting"]?.value.bool != true {
                say("\(what): the camera reports it after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s"
                    + (stale.map { String(format: " (reloading from %.1f s)", $0) } ?? " (no reload)"))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        say("\(what): not reported within 90 s (camera: \(await backend.currentReading?.text(field) ?? "?"))")
    }

    /// Each control the tiles drive, through the backend and back: the time until the camera itself reports it (the
    /// tile shows a write at once, as pending, so the backend's reading is what's watched).
    static func selftest(_ backend: ArriCameraBackend, _ latest: Latest) async {
        func confirmed(_ timeout: Double, from t0: Date, _ check: (ArriReading) -> Bool) async -> Double? {
            while Date().timeIntervalSince(t0) < timeout {
                if let r = await backend.currentReading, check(r) { return Date().timeIntervalSince(t0) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        func trip(_ name: String, to: CameraCommand, back: CameraCommand, isTo: (ArriReading) -> Bool,
                  isBack: (ArriReading) -> Bool) async {
            var t0 = Date()
            await backend.send(to)
            let there = await confirmed(5, from: t0, isTo)
            t0 = Date()
            await backend.send(back)
            let home = await confirmed(5, from: t0, isBack)
            say("\(name): camera took it in \(took(there)), back in \(took(home))")
        }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.05 } ?? false }
        let s = latest.state
        if let ei = s.iso?.value {
            let to = ei == 800 ? 1000 : 800
            await trip("EI \(ei) → \(to)", to: .setISO(to), back: .setISO(ei),
                       isTo: { $0.text(.ei).flatMap(ArriFormat.eiNumber) == to },
                       isBack: { $0.text(.ei).flatMap(ArriFormat.eiNumber) == ei })
        }
        if let nd = s.nd?.preset, let to = nd.options.first(where: { $0 != nd.value }) {
            await trip("ND \(nd.value) → \(to)", to: .setNDPreset(to), back: .setNDPreset(nd.value),
                       isTo: { $0.text(.nd).map(ArriFormat.ndLabel) == to },
                       isBack: { $0.text(.nd).map(ArriFormat.ndLabel) == nd.value })
        }
        if let k = s.whiteBalance?.kelvin.value {
            await trip("Kelvin \(Int(k)) → \(Int(k) + 300)", to: .setKelvin(k + 300), back: .setKelvin(k),
                       isTo: { near($0.value(.kelvin)?.number, k + 300) }, isBack: { near($0.value(.kelvin)?.number, k) })
        }
        if let t = s.whiteBalance?.tint?.value {
            await trip("CC \(t) → \(t + 1)", to: .setTint(t + 1), back: .setTint(t),
                       isTo: { near($0.value(.tint)?.number, t + 1) }, isBack: { near($0.value(.tint)?.number, t) })
        }
        if let a = s.shutterAngle?.value {
            let to: Double = a == 90 ? 180 : 90
            await trip("shutter \(a)° → \(to)°", to: .setShutterAngle(to), back: .setShutterAngle(a),
                       isTo: { near($0.value(.shutterAngle)?.number, to) }, isBack: { near($0.value(.shutterAngle)?.number, a) })
        }
        if let fps = s.frameRate?.project.value, let now = Double(fps) {
            let to = fps == "25" ? "24" : "25"
            await trip("fps \(fps) → \(to)", to: .setFrameRate(to), back: .setFrameRate(fps),
                       isTo: { near($0.value(.fps)?.number, Double(to)!) }, isBack: { near($0.value(.fps)?.number, now) })
        }
        for output in s.monitoring?.outputs ?? [] {
            for overlay in [MonitorOverlay.frameGuides, .lut, .focusAssist] {
                guard let on = output.overlays[overlay]?.value else { continue }
                let id = output.id
                func shows(_ r: ArriReading, _ want: Bool) -> Bool {
                    guard let sw = r.outputs.first(where: { $0.id == id })?.switches[overlay],
                          let v = r.snapshot.variables[sw.variable]?.value else { return false }
                    return sw.isOn(v) == want
                }
                await trip("\(output.name) \(overlay.rawValue) \(on) → \(!on)",
                           to: .setMonitorOverlay(overlay, !on, output: id), back: .setMonitorOverlay(overlay, on, output: id),
                           isTo: { shows($0, !on) }, isBack: { shows($0, on) })
            }
        }
    }
}
