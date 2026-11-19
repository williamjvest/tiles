// camctl shakedown: a shoot's camera, rigged as it will be on the day, read tile by tile to set beside its own screen,
// and with --write every control the app offers changed and put back through the app's own path (the API's field
// table, as the app and a deck set them), each read back. docs/testing.md, "Before a camera goes on a shoot".

import Foundation
import CameraCore
import SonyPTP
import SonySavona
import ArriWebRemote
import BlackmagicRESTBackend

@MainActor
enum Shakedown {
    /// What a shakedown never changes: REC and playback, what restarts the camera or changes the recording's format or
    /// picture, and what writes into the clips. Change those on the day, on purpose.
    static let neverWrite: Set<String> = [
        "record", "playbackMode", "playing", "frameRate", "frameRateVariable", "offSpeedRate", "resolution", "codec",
        "bitrate", "imagerMode", "shootingMode", "clipFlag", "imageFlip", "colorBars", "timecodeDuration",
    ]

    static func usage() {
        print("""
        camctl shakedown sony|bm|venice|arri <host> [--write] [--https]
          Reads every tile as the app would, to compare with the camera's own screen. --write also changes each control
          the app offers (not REC, playback, format, frame rate, imager or shooting mode) and puts it back, each read
          back. Sony: CAMCTL_SSH_USER / CAMCTL_SSH_PASSWORD for Access Authentication; a VENICE: CAMCTL_VENICE_PASSWORD;
          Blackmagic: CAMCTL_BM_PASSWORD where it has one.
        """)
    }

    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var state = CameraState()
        func set(_ s: CameraState) { lock.withLock { state = s } }
        var value: CameraState { lock.withLock { state } }
    }

    static func run(_ args: ArraySlice<String>) async {
        var it = args.makeIterator()
        guard let make = it.next(), let host = it.next() else { usage(); exit(1) }
        var write = false, https = false
        while let arg = it.next() {
            switch arg {
            case "--write": write = true
            case "--https": https = true
            default: usage(); exit(1)
            }
        }
        let env = ProcessInfo.processInfo.environment
        let backend: any CameraBackend
        switch make {
        case "sony": backend = makeSonyBackend(host: host, recorder: nil)
        case "bm": backend = BlackmagicCameraBackend.make(BlackmagicConnection(host: host, useHTTPS: https),
                                                         password: env["CAMCTL_BM_PASSWORD"])
        case "venice": backend = VeniceCameraBackend(host: host, password: env["CAMCTL_VENICE_PASSWORD"])
        case "arri": backend = ArriCameraBackend(host: host)
        default: usage(); exit(1)
        }
        let latest = Latest()
        let watching = Task { for await state in backend.updates { latest.set(state) } }
        let connecting = Task { await backend.connect() }
        defer { watching.cancel(); connecting.cancel() }

        // The first full reading, and a few seconds more for what a camera adds after it (an FX5's own controls, names).
        var ready: Date?
        for _ in 0..<300 {
            let s = latest.value
            if case .failed(let why) = s.connection { print("failed: \(why)"); exit(1) }
            if ready == nil, s.connection == .connected, s.hasReported { ready = Date() }
            if let ready, Date().timeIntervalSince(ready) > 4 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready != nil else { print("no reading from \(host) in 30 s"); exit(1) }

        print(checklist(latest.value, host: host))
        if write {
            print("\nChanging each control and putting it back:")
            var stuck: [String] = []
            for line in await roundTrips(latest: latest, send: { await backend.send($0) }, stuck: &stuck) { print(line) }
            if !stuck.isEmpty { print("\n!! Not put back, set these by hand: \(stuck.joined(separator: ", "))") }
        }
        print("\nStill never tried on a camera like this one: docs/feature-gaps.md, its section's \"Built, never on a camera\".")
        await backend.disconnect()
    }

    /// Every tile's reading, worded to be checked against the camera's own screen.
    static func checklist(_ s: CameraState, host: String) -> String {
        var lines = ["\(s.modelName ?? s.model ?? "Camera") at \(host): check each against the camera's own screen."]
        let battery = [s.batteryPercent.map { "\($0)%" }, s.batteryVolts.map { String(format: "%.1f V", $0) }, s.powerSource]
            .compactMap { $0 }
        lines.append("  Battery: \(battery.isEmpty ? "— (nothing the camera reports)" : battery.joined(separator: " "))")
        lines.append("  Media: \(s.mediaRemainingMinutes.map { "\($0) min" } ?? "—")")
        lines.append("  Camera's warnings: \(s.alerts.isEmpty ? "none" : s.alerts.joined(separator: ", "))")
        lines.append("  REC: \(s.recording.state)   Latency: \(s.latencyMilliseconds.map { "\($0) ms" } ?? "—")")
        if let clip = s.clipName { lines.append("  Next clip: \(clip)") }
        if let lens = s.focusDrive {
            lines.append("  Focus drive: \(lens.isWritable ? "live" : "greyed")\(lens.distance.map { ", \($0) m" } ?? "")")
        }
        if s.canAutoFocus { lines.append("  Push AF: \(s.canPushAutoFocus ? "live" : "greyed (AF on)")") }
        if !s.assignableButtons.isEmpty {
            lines.append("  Buttons: " + s.assignableButtons.map {
                "\($0.id) \($0.function)\($0.isOn == true ? " ON" : "")\($0.isPressable ? " (pressable)" : "")"
            }.joined(separator: " · "))
        }
        lines.append("  Every control (value · w = the app can change it · its options):")
        for f in ControlServer.fieldReadings(s) {
            let options = f.options.count > 8 ? "\(f.options.count) options" : f.options.joined(separator: ", ")
            lines.append("    \(f.name): \(f.value)\(f.isWritable ? " · w" : "")\(f.restarts ? " (restarts: left)" : "")"
                         + (options.isEmpty ? "" : " · [\(options)]"))
        }
        return lines.joined(separator: "\n")
    }

    /// Each control the app can change now, but `neverWrite`: to the option beside it, read back, then back, read back.
    static func roundTrips(latest: Latest, send: (CameraCommand) async -> Void, stuck: inout [String]) async -> [String] {
        var report: [String] = []
        for field in ControlServer.fieldReadings(latest.value)
            where field.isWritable && !field.restarts && !neverWrite.contains(field.name) {
            guard let i = field.options.firstIndex(of: field.value), field.options.count > 1 else { continue }
            let target = field.options[i + 1 < field.options.count ? i + 1 : i - 1]
            let original = field.value
            guard let there = ControlServer.command(field: field.name, option: target, state: latest.value) else {
                report.append("  \(field.name): \(original) → \(target): the app wouldn't build it"); continue
            }
            await send(there)
            let went = await reads(field.name, target, latest)
            guard let back = ControlServer.command(field: field.name, option: original, state: latest.value) else {
                report.append("  \(field.name): \(original) → \(target) \(went ? "✓" : "✗"), and no way back"); stuck.append(field.name); continue
            }
            await send(back)
            let returned = await reads(field.name, original, latest)
            let now = ControlServer.fieldReadings(latest.value).first { $0.name == field.name }?.value ?? "—"
            report.append("  \(field.name): \(original) → \(target) \(went ? "✓" : "✗ (the camera kept it)") → \(original) "
                          + (returned ? "✓" : "✗ (now \(now))"))
            if !returned { stuck.append("\(field.name) (was \(original))") }
        }
        return report
    }

    /// Whether `field` reads `value` within 5 s.
    static func reads(_ field: String, _ value: String, _ latest: Latest) async -> Bool {
        for _ in 0..<50 {
            if ControlServer.fieldReadings(latest.value).first(where: { $0.name == field })?.value == value { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
