// camctl bm — the app's Blackmagic backend against a real camera: what it reads, and what each control does.

import Foundation
import ImageIO
import CoreGraphics
import CameraCore
import BlackmagicRESTBackend

/// camctl bm <host> [--https] [--login user:password] state     (or the login in CAMCTL_BM_LOGIN, which `ps` doesn't show)
/// camctl bm <host> --remote-password <password> state           (Remote Control: port 444, HTTPS; or CAMCTL_BM_REMOTE)
///   Each makes the backend from a saved connection the way the app does (`BlackmagicCameraBackend.make`). The host
///   may be usb:<serial> (`camctl usb` lists them): found on its cable, as the app finds it.
/// camctl bm <host> [--https] [--layout-check] watch <seconds>   (--layout-check: the presets checked as on software
///                                                             Tiles hasn't checked, before they're used)
/// camctl bm <host> [--https] set <iso|angle|speed|mode|kelvin|tint|wb|iris|nd|ndvar|fps|offspeed|offrate|res|format|setting|lut|look|falsecolor|bars|focus|dynrange|zebralevel|guideratio|reel|camid> <value>
/// camctl bm <host> [--https] set <lut|falsecolor|zebra|focusassist|guides|grids|safe|clean>@<output> <on|off>   (one output)
/// camctl bm <host> [--https] set <zebra|focusassist|guides|grids|safe|clean> <on|off>                          (every output)
/// camctl bm <host> [--https] set tally <Off|Green|Red>
/// camctl bm <host> [--https] set <audiogain|audioinput|audiolowcut|audiopad|audiophantom>@<channel> <value>
/// camctl bm <host> [--https] af                      (one-shot autofocus, with a lens the camera can focus)
/// camctl bm <host> [--https] stay <seconds>          (the app's own store with this camera: each change of its
///                                                      connection, reconnecting as the app does, and at once when a
///                                                      camera on USB is plugged back in)
/// camctl bm <host> [--https] rec <start|stop>
/// camctl bm <host> [--https] play <review|live|toggle|stop|next|prev|ff|rew>
/// camctl bm <host> [--https] [--stream-to <relay>] [--again <s>] [--restart] [--review-stop]
///                  [--rc-linger <s>] liveview <seconds> [low|high] [last-frame.png]
///                                                                              (live view through the livestream)
/// camctl rtmp-listen <seconds> [--trace]                                      (the receiver alone, for any publisher)
func runBlackmagic(_ arguments: [String]) {
    var args = arguments
    let https = args.contains("--https")
    args.removeAll { $0 == "--https" }
    // --layout-check: the camera's presets checked as other software's are, before they're used (Activity Log).
    let layoutCheck = args.contains("--layout-check")
    args.removeAll { $0 == "--layout-check" }
    // --stream-to <address>: where the camera streams live view to, through a relay (default: this machine).
    var streamTo: String?
    if let i = args.firstIndex(of: "--stream-to"), i + 1 < args.count {
        streamTo = args[i + 1]
        args.removeSubrange(i ... i + 1)
    }
    // --review-stop: live view's stream stopped the documented way (Review), not through Remote Control.
    let reviewStop = args.contains("--review-stop")
    args.removeAll { $0 == "--review-stop" }
    // --restart: after the first look, the camera's stream stopped now and live view started again straight away.
    let restart = args.contains("--restart")
    args.removeAll { $0 == "--restart" }
    // A flag's seconds, refused rather than ignored when they aren't a number: an experiment that quietly ran with the
    // default would measure the wrong thing.
    func seconds(after flag: String) -> Double? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count, let value = Double(args[i + 1]), value >= 0 else {
            print("\(flag) wants a number of seconds"); exit(1)
        }
        args.removeSubrange(i ... i + 1)
        return value
    }
    // --rc-linger <seconds>: the stream's linger on a camera with Remote Control (the app's is 15 s).
    let remoteControlLinger = seconds(after: "--rc-linger")
    // --again <seconds>: close live view, wait, open it again (the stream is picked up, not restarted), then end.
    let again = seconds(after: "--again")
    // The camera's network access login, when it has one: CAMCTL_BM_LOGIN, or --login (which `ps` shows), user:password.
    var credentials = ProcessInfo.processInfo.environment["CAMCTL_BM_LOGIN"]
    if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
        credentials = args[i + 1]
        args.removeSubrange(i ... i + 1)
    }
    var remotePassword = ProcessInfo.processInfo.environment["CAMCTL_BM_REMOTE"]
    if let i = args.firstIndex(of: "--remote-password"), i + 1 < args.count {
        remotePassword = args[i + 1]
        args.removeSubrange(i ... i + 1)
    }
    guard args.count >= 2 else { printUsage(); exit(1) }
    let host = args[0], verb = args[1], rest = Array(args.dropFirst(2))

    // A saved connection, as Edit Camera would make it.
    let connection: BlackmagicConnection
    let password: String?
    if let remotePassword, !remotePassword.isEmpty {
        connection = BlackmagicConnection(host: host, useHTTPS: true, remoteControl: true)
        password = remotePassword
    } else {
        let parts = (credentials ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        connection = BlackmagicConnection(host: host, useHTTPS: https, username: parts.first)
        password = parts.count > 1 ? parts[1] : nil
    }
    if verb == "stay" {
        MainActor.assumeIsolated { stayConnected(connection, password: password, seconds: rest.first.flatMap(Double.init) ?? 60) }
        return
    }
    let backend = BlackmagicCameraBackend.make(connection, password: password)

    if verb == "liveview" {
        runBlackmagicLiveView(backend, reviewStop: reviewStop, restart: restart,
                              remoteControlLinger: remoteControlLinger, seconds: rest.first.flatMap(Double.init) ?? 10,
                              quality: rest.dropFirst().first == "high" ? .high : .low, save: rest.dropFirst(2).first,
                              streamTo: streamTo, again: again)
        return
    }
    let command: CameraCommand?
    switch verb {
    case "state", "watch": command = nil
    case "set":
        guard rest.count >= 2, let made = blackmagicSetCommand(rest[0], rest[1]) else {
            print("set needs a known name and a value"); exit(1)
        }
        command = made
    case "rec":
        guard let what = rest.first, ["start", "stop"].contains(what) else { print("rec start|stop"); exit(1) }
        command = .record(what == "start")
    case "af":
        command = .autoFocus
    case "play":
        let commands: [String: PlaybackCommand] = ["review": .review, "live": .live, "toggle": .togglePlay, "stop": .stop,
                                                   "next": .next, "prev": .previous, "ff": .fastForward, "rew": .rewind]
        guard let name = rest.first, let made = commands[name] else { print("play \(commands.keys.sorted().joined(separator: "|"))"); exit(1) }
        command = .playback(made)
    default:
        printUsage(); exit(1)
    }
    let watchFor = verb == "watch" ? Double(rest.first ?? "") ?? 30 : (command == nil ? 0 : 3)

    let sema = DispatchSemaphore(value: 0)
    Task {
        let started = Date()
        if layoutCheck { await backend.useLayoutCheck() }
        await backend.connect()
        var last: [String] = []
        var ready = false
        var sentAt: Date?
        for await state in backend.updates {
            let elapsed = String(format: "%5.2fs", Date().timeIntervalSince(started))
            if case .failed(let message) = state.connection { print("\(elapsed) failed: \(message)"); break }
            // The watch is over (the stream itself never ends).
            if ready, state.connection == .disconnected { break }
            guard state.connection == .connected, state.hasReported else { continue }
            let lines = blackmagicSummary(state)
            if !ready {
                ready = true
                print("\(elapsed) connected")
                lines.forEach { print("  \($0)") }
                last = lines
                if let command {
                    // After the WebSocket has subscribed, or the camera's answer can come before anyone listens.
                    sentAt = Date().addingTimeInterval(0.5)
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        print(String(format: "%5.2fs send \(command)", Date().timeIntervalSince(started)))
                        await backend.send(command)
                    }
                }
                if watchFor == 0 { break }
                Task { try? await Task.sleep(for: .seconds(watchFor)); await backend.disconnect() }
                continue
            }
            // What changed since the last report, and how long after the command it came.
            let changed = lines.filter { !last.contains($0) }
            if !changed.isEmpty {
                let after = sentAt.map { String(format: " (+%.2fs after send)", Date().timeIntervalSince($0)) } ?? ""
                print("\(elapsed) changed\(after):")
                changed.forEach { print("  \($0)") }
            }
            last = lines
        }
        await backend.disconnect()
        // What the backend noted on the way (a subscription the camera refused, say).
        let log = ActivityLog.shared.text
        if !log.isEmpty { print("activity log:\n\(log)") }
        sema.signal()
    }
    waitServicingMain(sema)
}

private func blackmagicSetCommand(_ name: String, _ value: String) -> CameraCommand? {
    let overlays: [String: MonitorOverlay] = ["lut": .lut, "falsecolor": .falseColor, "zebra": .zebra,
                                              "focusassist": .focusAssist, "guides": .frameGuides, "grids": .frameGrids,
                                              "safe": .safeArea, "clean": .cleanFeed, "status": .statusText]
    // "clean@MainSDI on": one output.
    let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
    // "textfor@MainSDI director": what that output's status text shows.
    if parts.count == 2, parts[0] == "textfor" {
        return StatusTextContent.allCases.first { $0.rawValue.lowercased() == value.lowercased() }
            .map { .setStatusTextContent($0, output: parts[1]) }
    }
    if parts.count == 2, let overlay = overlays[parts[0]] { return .setMonitorOverlay(overlay, value == "on", output: parts[1]) }
    // "audiogain@0 12": one of the camera's audio channels, by its index from 0 (`state` lists them).
    if parts.count == 2, parts[0].hasPrefix("audio"), let channel = Int(parts[1]) {
        let setting: AudioSetting? = switch parts[0] {
        case "audiogain": Double(value).map { .gain($0) }
        case "audioinput": .input(value)
        case "audiolowcut": .lowCut(value == "on")
        case "audiopad": .pad(value == "on")
        case "audiophantom": .phantomPower(value == "on")
        default: nil
        }
        return setting.map { .setAudio(channel: channel, $0) }
    }
    if let overlay = overlays[name], ![MonitorOverlay.lut, .falseColor].contains(overlay) {
        return .setMonitorOverlay(overlay, value == "on", output: nil)
    }
    return switch name {
    case "iso": Int(value).map { .setISO($0) }
    case "baseiso": Int(value).map { .setBaseISO($0) }
    case "angle": Double(value).map { .setShutterAngle($0) }
    case "speed": .setShutterSpeed(value)
    case "mode": .setShutterMode(value == "speed" ? .speed : .angle)
    case "kelvin": Double(value).map { .setKelvin($0) }
    case "tint": Double(value).map { .setTint($0) }
    case "iris": Double(value).map { .setIris($0) }
    case "nd": .setNDPreset(value)
    case "ndvar": Double(value).map { .setVariableND($0) }
    case "fps": .setFrameRate(value)
    case "offspeed": .setFrameRateVariable(value == "on")
    case "offrate": Double(value).map { .setFrameRateVariableRate($0) }
    case "dynrange": .setDynamicRange(value)
    case "desqueeze": .setDesqueeze(value)
    case "zebralevel": Int(value).map { .setZebraLevel($0) }
    case "guideratio": .setFrameGuideRatio(value)
    case "reel": Int(value).map { .setClipReel($0) }
    case "camid": .setClipCameraID(value)
    case "res": .setResolution(value)
    case "format": .setFileFormat(value)
    case "setting": .setRecordingSetting(value)
    case "lut": .setLUT(value)
    case "look": .setLook(value == "on")
    case "falsecolor": .setFalseColor(value == "on")
    case "bars": .setColorBars(value == "on")
    case "focus": .setFocusMode(value)
    case "wb": .setWhiteBalancePreset(value)
    case "tally": .setTally(value)
    default: nil
    }
}

/// One line per thing the dashboard would show, so a change reads as a changed line.
private func blackmagicSummary(_ s: CameraState) -> [String] {
    func choice<T>(_ name: String, _ c: Choice<T>?) -> String {
        guard let c else { return "\(name): —" }
        let options = c.options.isEmpty ? "" : " (\(c.options.count) options)"
        return "\(name): \(c.shown)\(c.isWritable ? "" : " read-only")\(options)"
    }
    func level(_ name: String, _ l: Level?) -> String {
        guard let l else { return "\(name): —" }
        return "\(name): \(l.shown) [\(l.range.lowerBound)…\(l.range.upperBound) step \(l.step)]\(l.isWritable ? "" : " read-only")"
    }
    var lines = [
        "model: \(s.model ?? "—")",
        "recording: \(s.recording.state)\(s.recording.request.map { " (requested \($0))" } ?? "")\(s.recording.failure.map { " FAILED \($0)" } ?? "")",
        "timecode: \(s.timecode.map { "\($0.isRunning ? "running" : "stopped") at \($0.rate) fps" } ?? "—")",
        choice("iso", s.iso), "native iso: \(s.nativeISOs.isEmpty ? "—" : s.nativeISOs.map(String.init).joined(separator: ", "))",
        choice("base iso", s.baseISO),
        choice("shutter angle", s.shutterAngle), choice("shutter speed", s.shutterSpeed), choice("shutter mode", s.shutterMode),
        choice("frame rate", s.frameRate?.project), choice("off-speed", s.frameRate?.variable),
        choice("off-speed rate", s.frameRate?.variableRate), choice("dynamic range", s.dynamicRange),
        choice("wb preset", s.whiteBalance?.preset) + " " + (s.whiteBalance?.preset.options.joined(separator: ",") ?? ""),
        level("kelvin", s.whiteBalance?.kelvin), level("tint", s.whiteBalance?.tint),
        choice("nd", s.nd?.preset), level("nd variable", s.nd?.variable),
        choice("iris", s.iris), choice("focus", s.focusMode),
        "format: \(s.recordingFormat ?? "—")",
        choice("resolution", s.resolution), choice("file format", s.fileFormat), choice("recording setting", s.recordingSetting),
        choice("desqueeze", s.desqueeze), choice("lut", s.lut), choice("look", s.look), choice("false colour", s.falseColor),
        choice("bars", s.colorBars),
        choice("tally", s.tally), "autofocus: \(s.canAutoFocus ? "can" : "can't")",
        "audio: \(s.audioChannels.isEmpty ? "—" : s.audioChannels.map(audioLine).joined(separator: "; "))",
        "audio inputs: \(s.audioChannels.first?.input?.options.joined(separator: ", ") ?? "—")",
        "battery: \(s.batteryPercent.map { "\($0)%" } ?? "—") \(s.batteryVolts.map { String(format: "%.1f V", $0) } ?? "— V") "
            + "media: \(s.mediaRemainingMinutes.map { "\($0) min" } ?? "—")",
        "clip: \(s.clipName ?? "—")\(s.fileNaming.map { n in " camera \(n.cameraID?.shown ?? "—") reel \(n.reel.map { String(Int($0.shown)) } ?? "—")\(n.failure.map { " FAILED \($0)" } ?? "")" } ?? "")",
        "monitoring: \(s.monitoring.map { m in m.outputs.map { o in "\(o.name)[\(MonitorOverlay.allCases.filter { o.overlays[$0]?.shown == true }.map(\.title).joined(separator: ","))]\(o.statusTextContent.map { " for \($0.shown.title)" } ?? "")" }.joined(separator: " ") + " zebra \(m.zebraLevel.map { "\($0.shown)%" } ?? "—") guides \(m.frameGuideRatio?.shown ?? "—") (\(m.frameGuideRatio?.options.count ?? 0) ratios)" } ?? "—")",
        "playback: \(s.playback.map { "\($0)" } ?? "—")",
        "live view: \(s.hasLiveView)",
        "latency: \(s.latencyMilliseconds.map { "\($0) ms" } ?? "—")",
    ]
    if !s.warnings.isEmpty { lines.append("warnings: \(s.warnings.joined(separator: " | "))") }
    return lines
}

/// The app's own store with this one camera for `seconds`, printing each change of its connection as the dashboard
/// shows it. It reconnects as the app does: after 1, 2, 4 and 8 s, then every 10 s, and at once when a camera on USB is
/// plugged back in. Runs the main run loop, where the store and the USB notifications live.
@MainActor
private func stayConnected(_ connection: BlackmagicConnection, password: String?, seconds: Double) {
    let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: connection.host), connection: .blackmagic(connection))
    let page = CameraPage(id: UUID(), name: "A", cameraIDs: [camera.slot.id], showsAllCameras: false)
    let store = DashboardStore(cameras: [camera], pages: [page], startCameras: true) { _, _ in
        BlackmagicCameraBackend.make(connection, password: password)
    }
    let start = Date()
    var last = ""
    while Date().timeIntervalSince(start) < seconds {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let now = store.cameras.first.map { "\($0.state.connection)" } ?? "no camera"
        guard now != last else { continue }
        print(String(format: "%8.2fs", Date().timeIntervalSince(start)), now)
        last = now
    }
    store.cameras.forEach { $0.disconnect() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}

/// One audio channel: its input, gain and switches, as the Audio tile shows them.
private func audioLine(_ c: AudioChannel) -> String {
    let on = { (name: String, value: Choice<Bool>?) in value.map { " \(name) \($0.shown ? "on" : "off")\($0.isWritable ? "" : " (fixed)")" } ?? "" }
    return "[\(c.id)] \(c.input?.shown ?? "—") gain \(c.gain.map { "\($0.shown) dB [\($0.range.lowerBound)…\($0.range.upperBound)]" } ?? "—")"
        + on("48V", c.phantomPower) + on("low cut", c.lowCut) + on("pad", c.pad) + (c.isAvailable ? "" : " (nothing plugged in)")
}

/// Live view through the camera's livestream, as the app runs it: start, count pictures, stop (and time each).
private func runBlackmagicLiveView(_ backend: BlackmagicCameraBackend, reviewStop: Bool = false, restart: Bool = false,
                                   remoteControlLinger: Double? = nil,
                                   seconds: Double, quality: LiveViewQuality, save: String?, streamTo: String?,
                                   again: Double?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        await backend.setLiveViewStreamAddress(streamTo)
        if reviewStop { await backend.setStopsThroughRemoteControl(false) }
        if let remoteControlLinger { await backend.setRemoteControlLinger(.seconds(remoteControlLinger)) }
        let t0 = Date()
        func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
        Task { await backend.connect() }
        // Live view is offered once the livestream answers (after the monitoring burst).
        for await state in backend.updates {
            if case .failed(let message) = state.connection { print("\(stamp()) failed: \(message)"); exit(1) }
            if state.hasLiveView { break }
        }
        print("\(stamp()) connected, live view offered; starting the stream (\(quality))")
        do { try await backend.startLiveView(quality: quality) } catch { print("\(stamp()) start failed: \(error)"); exit(1) }
        print("\(stamp()) stream started")
        var last: CGImage?
        func watch(_ seconds: Double) async {
            var frames = 0
            var first: Date?
            let end = Date().addingTimeInterval(seconds)
            var gap = false
            while Date() < end {
                guard let frame = try? await backend.liveViewPicture(), let image = frame.image else {
                    print("\(stamp()) no picture in 3 s"); gap = true; continue
                }
                if first == nil { first = Date(); print("\(stamp()) first picture \(image.width)×\(image.height)") }
                if gap { gap = false; print("\(stamp()) pictures again") }
                frames += 1
                last = image
            }
            if let first { print(String(format: "%@ %d pictures, %.1f a second", stamp(), frames, Double(frames) / Date().timeIntervalSince(first))) }
        }
        await watch(seconds)
        if let again {
            print("\(stamp()) closing live view for \(again) s (the stream lingers)")
            await backend.stopLiveView()
            try? await Task.sleep(for: .seconds(again))
            do { try await backend.startLiveView(quality: quality) } catch { print("\(stamp()) start again failed: \(error)"); exit(1) }
            print("\(stamp()) live view open again")
            await watch(seconds)
        }
        if restart {
            print("\(stamp()) stopping the camera's stream now, then starting live view again")
            await backend.endLiveViewStream()
            print("\(stamp()) stopped")
            do { try await backend.startLiveView(quality: quality) } catch { print("\(stamp()) restart failed: \(error)"); exit(1) }
            print("\(stamp()) live view started again")
            await watch(seconds)
        }
        if let save, let last, let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: save) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, last, nil)
            if CGImageDestinationFinalize(destination) { print("\(stamp()) wrote \(save)") }
        }
        print("\(stamp()) stopping")
        await backend.endLiveViewStream()
        print("\(stamp()) stopped")
        let log = ActivityLog.shared.text
        if !log.isEmpty { print("activity log:\n\(log)") }
        sema.signal()
    }
    sema.wait()
}

/// The live view receiver alone: point any RTMP publisher at rtmp://<this machine>:1935/live/tiles.
func runRTMPListen(seconds: Double, trace: Bool = false) {
    let sema = DispatchSemaphore(value: 0)
    let t0 = Date()
    let stamped: @Sendable (String) -> Void = { line in print(String(format: "%.2fs ", Date().timeIntervalSince(t0)) + line) }
    let tracer: (@Sendable (String) -> Void)? = trace ? stamped : nil
    Task {
        let listener = BlackmagicStreamListener(trace: tracer)
        do { print("listening on port \(try await listener.start())") } catch { print("can't listen: \(error)"); exit(1) }
        var first: CGImage?
        while Date().timeIntervalSince(t0) < seconds {
            if let image = await listener.nextFrame(timeout: .seconds(1)), first == nil {
                first = image
                print(String(format: "%.2fs first picture %d×%d", Date().timeIntervalSince(t0), image.width, image.height))
            }
        }
        print("\(listener.frameCount) pictures in \(Int(seconds)) s")
        listener.stop()
        sema.signal()
    }
    sema.wait()
}
