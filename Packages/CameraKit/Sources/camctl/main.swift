// camctl — Sony PTP-IP camera CLI

import Foundation
import SonyPTP
import CameraCore
import SonySavona

setvbuf(stdout, nil, _IOLBF, 0)  // piped output survives a timeout kill

// MARK: - Argument parsing

var args = CommandLine.arguments.dropFirst()  // drop executable name

var recordFile: String? = nil
// Parse --record
if let idx = args.firstIndex(of: "--record"), args.index(after: idx) < args.endIndex {
    recordFile = args[args.index(after: idx)]
    args.remove(at: idx)
    args.remove(at: idx)
}

guard let subcommand = args.first else {
    printUsage(); exit(1)
}
args = args.dropFirst()

// MARK: - Main dispatch

let recorder: (any TrafficRecorder)?
if let path = recordFile {
    recorder = try FileTrafficRecorder(path: path)
} else {
    recorder = nil
}

switch subcommand {
case "connect":
    guard let host = args.first else { printUsage(); exit(1) }
    runConnect(host: host, recorder: recorder)
case "dump":
    guard let host = args.first else { printUsage(); exit(1) }
    runDump(host: host, recorder: recorder)
case "set":
    guard args.count >= 3 else { printUsage(); exit(1) }
    let host = args[args.startIndex]
    let code = args[args.index(args.startIndex, offsetBy: 1)]
    let value = args[args.index(args.startIndex, offsetBy: 2)]
    runSet(host: host, codeOrName: code, value: value, recorder: recorder)
case "send":
    guard args.count >= 3 else { printUsage(); exit(1) }
    let host = args[args.startIndex]
    let name = args[args.index(args.startIndex, offsetBy: 1)]
    let value = args[args.index(args.startIndex, offsetBy: 2)]
    runSend(host: host, name: name, value: value, recorder: recorder)
case "decode":
    guard let path = args.first else { printUsage(); exit(1) }
    runDecode(path: path)
case "watch":
    guard let host = args.first else { printUsage(); exit(1) }
    let seconds = args.dropFirst().first.flatMap { Double($0) } ?? 60
    runWatch(host: host, seconds: seconds, recorder: recorder)
case "rec":
    guard args.count >= 2 else { printUsage(); exit(1) }
    let host = args[args.startIndex]
    let action = args[args.index(args.startIndex, offsetBy: 1)]
    runRec(host: host, action: action, recorder: recorder)
case "lut":
    guard let lutSubcmd = args.first else { printUsage(); exit(1) }
    args = args.dropFirst()
    switch lutSubcmd {
    case "list":
        guard let host = args.first else { printUsage(); exit(1) }
        runLUTList(host: host, recorder: recorder)
    case "import":
        guard let host = args.first else { printUsage(); exit(1) }
        args = args.dropFirst()
        guard let cubePath = args.first else { printUsage(); exit(1) }
        args = args.dropFirst()
        // Parse --slot N and optional --name "..."
        var slotN: Int? = nil
        var displayName: String? = nil
        let remaining = Array(args)
        var i = 0
        while i < remaining.count {
            if remaining[i] == "--slot", i + 1 < remaining.count {
                slotN = Int(remaining[i + 1]); i += 2
            } else if remaining[i] == "--name", i + 1 < remaining.count {
                displayName = remaining[i + 1]; i += 2
            } else { i += 1 }
        }
        guard let slot = slotN else { fputs("--slot N is required\n", stderr); exit(1) }
        runLUTImport(host: host, cubePath: cubePath, slot: slot, displayName: displayName, recorder: recorder)
    default:
        printUsage(); exit(1)
    }
case "keys":
    guard args.count >= 3 else { printUsage(); exit(1) }
    runKeys(host: args[args.startIndex], outDir: args[args.index(after: args.startIndex)], steps: Array(args.dropFirst(2)),
            recorder: recorder)
case "liveview":
    guard let host = args.first else { printUsage(); exit(1) }
    let lvArgs = Array(args.dropFirst())
    let frameCount = lvArgs.first.flatMap { Int($0) } ?? 10
    let savePath = lvArgs.dropFirst().first
    runLiveView(host: host, frameCount: frameCount, savePath: savePath, recorder: recorder)
case "halow":
    runHaLow(addresses: Array(args))
case "bm":
    runBlackmagic(Array(args))
case "rtmp-listen":
    // --trace: each connection's steps as they come (the handshake, every command, the first video messages).
    runRTMPListen(seconds: args.first(where: { $0 != "--trace" }).flatMap(Double.init) ?? 15, trace: args.contains("--trace"))
case "find":
    // The cameras on this Mac's networks, each as it's found, as Add Camera lists them: Sony cameras with Camera Remote
    // Control on (SSDP, and every address asked for its description on 64321), Blackmagic cameras by their Bonjour
    // adverts.
    let seconds = args.first.flatMap(Double.init) ?? 3
    let start = Date()
    var found = 0
    func elapsed() -> String { String(format: "%5.2fs", Date().timeIntervalSince(start)) }
    for await camera in NetworkCameras.search(seconds: seconds) {
        found += 1
        print(elapsed(), camera.host, camera.maker.label, camera.name, camera.model.map { "(\($0))" } ?? "",
              camera.needsLogin ? "Access Authentication: user name and password" : "")
    }
    print(elapsed(), found == 0 ? "No camera found." : "\(found) found.")
case "probe":
    // What an address answers as (what Add Camera says): an ARRI Web Remote, or which Sony protocol.
    guard let host = args.first else { print("camctl probe HOST"); exit(2) }
    if case .arri(let model) = await ArriRemoteProbe.probe(host: host) {
        print("ARRI web remote (\(model ?? "model not given as text"))")
    } else {
        let found = await SonyRemoteProbe.probe(host: host)
        print(found.map { $0 == .webRemote ? "web remote (VENICE / Savona)" : "camera remote (PTP-IP)" } ?? "unreachable")
    }
case "venice":
    // A VENICE / VENICE 2 over its Web Remote (Savona). One process-wide actor hop; commands run one at a time.
    await VeniceCLI.run(args)
case "shakedown":
    // Before a shoot: every tile read to check against the camera's screen, and with --write each control changed and
    // put back (docs/testing.md).
    await Shakedown.run(args)
case "arri":
    // An ARRI camera (ALEXA Mini, Mini LF, ALEXA 35, AMIRA) over its Web Remote, or a capture of one.
    await ArriCLI.run(args)
case "usb":
    // camctl usb: the cameras on this Mac's USB, a Blackmagic one with where its cable reaches it.
    // camctl usb watch <seconds>: each camera plugged in meanwhile, as the app's reconnect hears of it.
    #if os(macOS)
    let cameras = USBCamera.connected(), blackmagic = BlackmagicUSBCamera.connected()
    if cameras.isEmpty && blackmagic.isEmpty { print("No Sony or Blackmagic camera on USB.") }
    for camera in cameras {
        print("\(camera.product)  \(camera.host)  \(camera.isRemoteShooting ? "Remote Shooting" : "not in Remote Shooting (USB Connection Mode)")")
    }
    for camera in blackmagic {
        print("\(camera.product)  \(camera.host)  \(camera.interface)  \(BlackmagicUSBLink.find(serial: camera.serial))")
    }
    if args.first == "watch" {
        let seconds = args.dropFirst().first.flatMap(Double.init) ?? 60
        let start = Date()
        let arrivals = USBCameraArrivals { host in
            print(String(format: "%6.2f", Date().timeIntervalSince(start)), "plugged in:", host)
            if let serial = USBCameraAddress.serial(in: host) {
                Task { @MainActor in
                    let finding = (try? await BlackmagicUSBLink.address(serial: serial)).map { "at \($0)" } ?? "\(BlackmagicUSBLink.find(serial: serial))"
                    print(String(format: "%6.2f", Date().timeIntervalSince(start)), host, finding)
                }
            }
        }
        arrivals.start(blackmagic: true)
        try? await Task.sleep(for: .seconds(seconds))
        _ = arrivals
    }
    #endif
    // camctl usb bonjour <seconds>: what an iPhone or iPad finds, through the cameras' Bonjour adverts: each advert
    // as it comes and goes, the cameras on a cable, and where each is found.
    // --resolve: ask every advert's address as an iPhone asks one on its Personal Hotspot, and print it.
    if args.first == "bonjour" {
        let resolve = args.contains("--resolve")
        let seconds = args.dropFirst().first(where: { !$0.hasPrefix("--") }).flatMap(Double.init) ?? 10
        let start = Date()
        let stamp: @Sendable () -> String = { String(format: "%6.2f", Date().timeIntervalSince(start)) }
        let adverts = BlackmagicAdverts.shared
        adverts.resolvesEveryAdvert = resolve
        let watch = adverts.watch { advert in
            print(stamp(), "advert:", advert.product, advert.host, advert.interface, advert.link.rawValue)
        }
        adverts.start()
        var last: [BlackmagicAdverts.Advert] = []
        var told: [String: String] = [:]
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(250))
            if resolve {
                adverts.resolveHotspotAdverts()
                for (key, address) in adverts.resolved where told[key] != address {
                    told[key] = address
                    print(stamp(), "resolved:", key, "at", address)
                }
            }
            let cables = adverts.onCables()
            guard cables != last else { continue }
            last = cables
            print(stamp(), "on a cable:", cables.isEmpty ? "none" : cables.map { "\($0.product) \($0.host) on \($0.interface)" }.joined(separator: ", "))
            for camera in cables {
                let found = (try? await BlackmagicUSBLink.addressFromAdverts(serial: camera.serial, patience: .seconds(3)))
                print(stamp(), camera.host, found.map { "at \($0)" } ?? "not found")
            }
        }
        adverts.stopWatching(watch)
    }
default:
    printUsage(); exit(1)
}

// MARK: - Commands

/// Waits on the main thread without blocking it: ImageCaptureCore (a camera on USB through it) works on the main
/// queue, which a plain `sema.wait()` here would stall for good.
func waitServicingMain(_ sema: DispatchSemaphore) {
    while sema.wait(timeout: .now() + 0.01) == .timedOut {
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, false)
    }
}


func runConnect(host: String, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host)...")
        await backend.connect()

        for await state in backend.updates {
            switch state.connection {
            case .awaitingApproval:
                print("Waiting for pairing approval on camera...")
            case .connected:
                print("Connected to \(host)")
                if let model = state.model { print("   Model: \(model)") }
                if let pct = state.batteryPercent { print("   Battery: \(pct)%") }
                if let media = state.mediaRemainingMinutes { print("   Media remaining: \(media) min") }
                // Closed before exiting: a session left open on a camera cabled by USB (an FX5, 2026-11-14) then
                // refused every command, the PTP device reset included, until the cable came out.
                await backend.disconnect()
                sema.signal(); return
            case .failed(let msg):
                fputs("Failed: \(msg)\n", stderr)
                sema.signal(); return
            case .disconnected:
                print("Disconnected.")
                sema.signal(); return
            default:
                break
            }
        }
    }
    waitServicingMain(sema)
}

actor LatestState {
    private(set) var state: CameraState?
    func set(_ newState: CameraState) { state = newState }
}

func runDump(host: String, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host) for dump...")
        await backend.connect()

        // The model string and the LUT names arrive a moment after the first connected state, so dump the
        // newest state 3 s after connecting rather than the first one (which showed "unknown model").
        let latest = LatestState()
        var connected = false
        for await state in backend.updates {
            await latest.set(state)
            switch state.connection {
            case .awaitingApproval:
                print("Waiting for pairing approval on camera...")
            case .connected:
                if !connected {
                    connected = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if let newest = await latest.state { await printFullDump(backend: backend, state: newest) }
                        await backend.disconnect()
                        sema.signal()
                    }
                }
            case .failed(let msg):
                fputs("Failed: \(msg)\n", stderr); sema.signal(); return
            case .fingerprintChanged(let observed):
                fputs("SSH host key \(observed) doesn't match the pinned fingerprint\n", stderr); sema.signal(); return
            default: break
            }
        }
    }
    waitServicingMain(sema)
}

func runSet(host: String, codeOrName: String, value: String, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host)...")
        await backend.connect()

        for await state in backend.updates {
            if state.connection == .connected {
                if MediaSafety.refuses(codeOrName) {
                    fputs(MediaSafety.refusal(codeOrName) + "\n", stderr)
                } else if let propCode = resolvePropertyCode(codeOrName) {
                    await setProperty(backend: backend, code: propCode, value: value)
                    print("Set 0x\(String(propCode, radix: 16)) = \(value)")
                } else {
                    fputs("Unknown property code or name: \(codeOrName)\n", stderr)
                }
                await backend.disconnect()
                sema.signal(); return
            } else if case .failed(let msg) = state.connection {
                fputs("Failed: \(msg)\n", stderr); sema.signal(); return
            }
        }
    }
    waitServicingMain(sema)
}

func runRec(host: String, action: String, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host)...")
        await backend.connect()

        for await state in backend.updates {
            switch state.connection {
            case .awaitingApproval:
                print("Waiting for pairing approval on camera...")
            case .connected:
                // The backend ignores REC until it knows the recording state, and .connected can arrive
                // before the first property fetch.
                guard state.recording.state != .unknown else { continue }
                let start = action.lowercased() == "start"
                print("\(start ? "Starting" : "Stopping") recording...")
                let sent = Date()
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    fputs("No REC outcome after 30 s — check camera.\n", stderr); exit(3)
                }
                await backend.send(.record(start))
                // Wait for THIS request's outcome. The update stream holds states from before the request was
                // set (request == nil), which must be skipped.
                var sawRequest = false
                for await s2 in backend.updates {
                    if s2.recording.request != nil { sawRequest = true; continue }
                    guard sawRequest else { continue }
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(sent))
                    if let failure = s2.recording.failure {
                        fputs("REC failed after \(seconds) s: \(failure)\n", stderr)
                    } else {
                        print("Camera confirms \(s2.recording.state == .recording ? "RECORDING" : "STOPPED") after \(seconds) s")
                    }
                    break
                }
                sema.signal(); return
            case .failed(let msg):
                fputs("Failed: \(msg)\n", stderr); sema.signal(); return
            case .fingerprintChanged(let observed):
                fputs("SSH host key \(observed) doesn't match the pinned fingerprint\n", stderr); sema.signal(); return
            default: break
            }
        }
    }
    waitServicingMain(sema)
}

/// Stay connected for `seconds`, then disconnect cleanly. With --record this measures what an idle connected
/// camera costs on the link.
func runWatch(host: String, seconds: Double, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        await backend.connect()
        var watching = false
        for await state in backend.updates {
            if case .failed(let msg) = state.connection { fputs("Failed: \(msg)\n", stderr); sema.signal(); return }
            if state.connection == .connected, !watching {
                watching = true
                print("Connected; watching \(Int(seconds)) s")
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    await backend.disconnect()
                    sema.signal()
                }
            }
        }
    }
    waitServicingMain(sema)
}

/// Offline: what the app makes of a saved full property dump (e.g. fixtures/fx3-propinfo-full.bin). For each
/// picker property, the camera's two enumeration lists: Set (what it will take now) and Get/Set (everything).
func runDecode(path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let props = try? parseSDIDevicePropInfoArray(data) else { print("can't read \(path)"); exit(1) }
    let byCode = Dictionary(props.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    print("\(props.count) properties")
    let watch: [(UInt16, String)] = [
        (0xD286, "frame rate"), (0xD241, "file format"), (0xD242, "recording setting"), (0xD051, "S&Q mode"),
        (0xD052, "S&Q frame rate"), (0xD0D0, "S&Q rec frame rate"), (0xD024, "resolution"), (0xE0A4, "desqueeze"),
        (0x5007, "iris"), (0xD022, "EI"), (0xD21E, "ISO"), (0xD020, "base ISO"), (0xD00E, "shutter angle"),
        (0xD20D, "shutter speed"), (0xD010, "shutter mode"), (0x500A, "focus mode"), (0xD03C, "base look"),
        (0xD04D, "monitor LUT"), (0x5005, "WB mode"), (0xD20F, "kelvin"), (0xD210, "tint"),
    ]
    var state = CameraState()
    StateMapper(props: props).map(into: &state)
    func show<T>(_ name: String, _ choice: Choice<T>?) {
        guard let choice else { print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) — (not offered)"); return }
        print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(choice.value)  \(choice.isWritable ? "settable" : "READ-ONLY")  options: \(choice.options.map { "\($0)" }.joined(separator: ", "))")
    }
    print("Mapped (what the tiles get):")
    show("shutter angle", state.shutterAngle); show("shutter speed", state.shutterSpeed); show("shutter mode", state.shutterMode)
    show("frame rate", state.frameRate?.project); show("S&Q", state.frameRate?.variable)
    show("S&Q rate", state.frameRate?.variableRate)
    print("  battery          \(state.batteryPercent.map { "\($0)%" } ?? "—")  volts \(state.batteryVolts.map { String(format: "%.1f V", $0) } ?? "—")")
    show("ISO/EI", state.iso); show("base ISO", state.baseISO); show("WB preset", state.whiteBalance?.preset)
    if let wb = state.whiteBalance {
        print("  kelvin           \(wb.kelvin.value)  \(wb.kelvin.isWritable ? "settable" : "READ-ONLY")  range \(wb.kelvin.range)")
        if let tint = wb.tint { print("  tint             \(tint.value)  \(tint.isWritable ? "settable" : "READ-ONLY")  range \(tint.range)") }
    } else { print("  white balance    — (not offered)") }
    show("iris", state.iris); show("focus", state.focusMode); show("ND", state.nd?.preset)
    show("resolution", state.resolution); show("codec", state.fileFormat); show("bitrate", state.recordingSetting)
    show("desqueeze", state.desqueeze); show("LUT", state.lut); show("LUT On", state.look)
    show("colour bars", state.colorBars); show("false colour", state.falseColor); show("sensor flip", state.imageFlip)
    show("hdmi info", state.hdmiInfo); show("grid lines", state.gridLines)
    print("Raw lists:")
    for (code, name) in watch {
        guard let prop = byCode[code] else { print(String(format: "0x%04X %-18@ absent", code, name as NSString)); continue }
        print(String(format: "0x%04X %-18@ cur=%@ enabled=%@ set(%d)=%@ all(%d)=%@", code, name as NSString,
                     hex(prop.currentValue), "\(prop.isEnabled)", prop.enumValues.count,
                     prop.enumValues.prefix(24).map(hex).joined(separator: ","), prop.enumValuesAll.count,
                     prop.enumValuesAll.prefix(24).map(hex).joined(separator: ",")))
    }
}

// MARK: - Full property dump

func printFullDump(backend: SonyCameraBackend, state: CameraState) async {
    print("\nCamera dump: \(state.model ?? "unknown model")\n")

    // What the camera declared at connect: every property code and every control (button / remote key) code.
    if let info = await backend.declaredExtDeviceInfo {
        let hex = { (codes: [UInt16]) in codes.sorted().map { String(format: "0x%04X", $0) }.joined(separator: " ") }
        print("[ Declared at connect: \(info.propCodes.count) property codes, \(info.controlCodes.count) control codes ]")
        print("controls: \(hex(info.controlCodes))")
        print("properties: \(hex(info.propCodes))\n")
    }

    // Decoded properties
    print("[ Decoded properties ]")
    print("  Recording:    \(state.recording.state)")
    if let tc = state.timecode {
        print("  Timecode:     \(tc.string(at: Date()))")
    }
    if let sa = state.shutterAngle {
        print("  Shutter angle: \(sa.value)°")
    }
    if let fr = state.frameRate {
        print("  Frame rate:   \(fr.project.value)")
    }
    if let iso = state.iso {
        print("  ISO/EI:       \(iso.value)")
    }
    if let base = state.baseISO {
        print("  Base ISO:     \(base.value) (writable: \(base.isWritable), options: \(base.options.map(String.init).joined(separator: ", ")))")
    }
    if let wb = state.whiteBalance {
        print("  Kelvin:       \(wb.kelvin.value)K")
        if let tint = wb.tint { print("  Tint:         \(tint.value)") }
    }
    if let iris = state.iris {
        print("  Iris:         \(iris.value) (writable: \(iris.isWritable), \(iris.options.count) stops \(iris.options.first.map { "\($0)" } ?? "")…\(iris.options.last.map { "\($0)" } ?? ""))")
    }
    if let ss = state.shutterSpeed { print("  Shutter speed: \(ss.value) (writable: \(ss.isWritable), \(ss.options.count) options)") }
    if let sm = state.shutterMode { print("  Shutter mode: \(sm.value) (writable: \(sm.isWritable))") }
    if let fm = state.focusMode { print("  Focus mode:   \(fm.value) (writable: \(fm.isWritable), options: \(fm.options.joined(separator: ", ")))") }
    if let lut = state.lut { print("  LUT:          \(lut.value) (writable: \(lut.isWritable))\n                \(lut.options.joined(separator: " | "))") }
    if let nd = state.nd {
        print("  ND:           \(nd.preset.value)")
        if let v = nd.variable { print("  ND variable:  \(String(format: "%.3f", v.value))") }
    }
    if let ff = state.fileFormat { print("  File format:  \(ff.value) (options: \(ff.options.joined(separator: ", ")))") }
    if let rs = state.recordingSetting { print("  Rec setting:  \(rs.value)") }
    if let res = state.resolution { print("  Resolution:   \(res.value)") }
    if let ds = state.desqueeze { print("  Desqueeze:    \(ds.value) (options: \(ds.options.joined(separator: ", ")))") }
    if let look = state.look { print("  Look (GDA):   \(look.value ? "ON" : "OFF") (writable: \(look.isWritable))") }
    if let bat = state.batteryPercent {
        print("  Battery:      \(bat)%")
    }
    if let media = state.mediaRemainingMinutes {
        print("  Media:        \(media) min remaining")
    }
    if !state.warnings.isEmpty {
        print("  Warnings: \(state.warnings.joined(separator: ", "))")
    }

    // Raw property hex table
    print("\n[ Raw properties ]")
    // Swift Strings can't go through %s (it reads them as C strings and crashed on a real FX3), so pad by hand.
    func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }
    print("  " + pad("Code", 8) + "  " + pad("Type", 7) + "  " + pad("GetSet", 8) + " " + pad("Enabled", 8) + " Current (hex)")
    print("  " + String(repeating: "-", count: 60))
    let sorted = await backend.rawProperties.sorted { $0.key < $1.key }
    for (code, prop) in sorted {
        let currentDisplay: String
        switch prop.dataType {
        case .str:
            currentDisplay = "\"\(prop.stringValue)\""
        case _ where prop.dataType.isArray:
            let elems = prop.arrayValues.map { $0.map { String(format: "%02x", $0) }.joined() }
            currentDisplay = "[\(elems.joined(separator: ","))]"
        default:
            currentDisplay = prop.currentValue.map { String(format: "%02x", $0) }.joined()
        }
        let enabled: String
        switch prop.isEnabled {
        case .enabled:  enabled = "yes"
        case .disabled: enabled = "no"
        case .dispOnly: enabled = "disp"
        }
        let getset = prop.getSet == .getSet ? "r/w" : "r"
        print(String(format: "  0x%04X    0x%04X   ", code, prop.dataType.rawValue) + pad(getset, 8) + " " + pad(enabled, 8) + " " + currentDisplay)
    }
    // Which physical buttons and dials can be pressed remotely (SDIO_ControlDevice 0xD309 / 0xD30B).
    let buttonNames: [UInt16: String] = [0x01: "Up", 0x02: "Down", 0x03: "Left", 0x04: "Right", 0x05: "ENTER", 0x06: "MENU",
        0x07: "MS Up", 0x08: "MS Down", 0x09: "MS Left", 0x0A: "MS Right", 0x0B: "MS Enter", 0x10: "Fn", 0x11: "Playback",
        0x12: "Delete", 0x13: "Mode", 0x14: "C1", 0x15: "C2", 0x16: "C3", 0x17: "C4", 0x18: "C5", 0x19: "C6", 0x1A: "MOVIE",
        0x1B: "AEL", 0x1C: "AF-ON", 0x1D: "Home", 0x1E: "Clips", 0x1F: "Slot-Select", 0x20: "Display", 0x21: "C7",
        0x22: "Cancel/Back", 0x23: "Thumbnail"]
    for (code, label) in [(UInt16(0xD208), "emulatable buttons"), (0xD209, "buttons (multi)"), (0xD20A, "emulatable dials"),
                          (0xD20B, "levers"), (0xD20C, "button function status")] {
        guard let prop = sorted.first(where: { $0.key == code })?.value else { continue }
        let values = (prop.enumValuesAll.isEmpty ? prop.enumValues : prop.enumValuesAll).map { d -> UInt16 in
            d.count >= 2 ? UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8 : 0 }
        let shown = values.map { v in code == 0xD208 || code == 0xD209 ? String(format: "0x%02X %@", v, (buttonNames[v] ?? "?") as NSString)
                                                                    : String(format: "0x%04X", v) }
        print(String(format: "  0x%04X %@: ", code, label as NSString) + (shown.isEmpty ? "(none)" : shown.joined(separator: ", ")))
    }
    print("")
}

// MARK: - Property set dispatch

func setProperty(backend: SonyCameraBackend, code: UInt16, value: String) async {
    // Route to the appropriate CameraCommand by code
    switch code {
    case SDIPropCode.shutterAngle.rawValue:
        if let v = Double(value) { await backend.send(.setShutterAngle(v)) }
    case SDIPropCode.colorTemperature.rawValue:
        if let v = Double(value) { await backend.send(.setKelvin(v)) }
    case SDIPropCode.wbTint.rawValue:
        if let v = Double(value) { await backend.send(.setTint(v)) }
    case SDIPropCode.isoSensitivity.rawValue:
        if let v = Int(value) { await backend.send(.setISO(v)) }
    case SDIPropCode.exposureIndex.rawValue:
        if let v = Int(value) { await backend.send(.setISO(v)) }
    case SDIPropCode.ndFilter.rawValue:
        await backend.send(.setNDPreset(value))
    case SDIPropCode.ndFilterValue.rawValue:
        if let v = Double(value) { await backend.send(.setVariableND(v)) }
    default:
        print("No direct mapping for 0x\(String(code, radix:16)); use raw set if needed.")
    }
}

// MARK: - Helpers

/// Access Authentication, as the app does it: `CAMCTL_SSH_USER` and `CAMCTL_SSH_PASSWORD` in the environment make
/// the backend open its own SSH tunnel (libssh2) to <host>:22; `CAMCTL_SSH_FINGERPRINT` pins the host key.
/// Without them camctl speaks PTP-IP to <host>:15740 directly (pairing, or an external tunnel on 127.0.0.1).
func makeSonyBackend(host: String, recorder: (any TrafficRecorder)?) -> SonyCameraBackend {
    let env = ProcessInfo.processInfo.environment
    let store = FileIdentityStore(friendlyName: "camctl")
    var config = SonyBackendConfig()
    if env["CAMCTL_USB_VIA"] == "ica" { config.usbLink = .imageCapture }  // a usb: host through ImageCaptureCore
    config.streamLiveView = true  // an FX5's live view through its stream, which the app has off for now
    return SonyCameraBackend(host: host, identityStore: store, config: config, recorder: recorder,
                             sshUsername: env["CAMCTL_SSH_USER"], password: env["CAMCTL_SSH_PASSWORD"],
                             trustedFingerprint: env["CAMCTL_SSH_FINGERPRINT"])
}

func resolvePropertyCode(_ s: String) -> UInt16? {
    // Try numeric: 0xD21D or decimal
    if s.hasPrefix("0x") || s.hasPrefix("0X"),
       let v = UInt16(s.dropFirst(2), radix: 16) { return v }
    if let v = UInt16(s) { return v }
    // Try name (partial, case-insensitive)
    let lower = s.lowercased()
    let nameMap: [(String, UInt16)] = [
        ("shutterangle",   SDIPropCode.shutterAngle.rawValue),
        ("iso",            SDIPropCode.isoSensitivity.rawValue),
        ("ei",             SDIPropCode.exposureIndex.rawValue),
        ("kelvin",         SDIPropCode.colorTemperature.rawValue),
        ("tint",           SDIPropCode.wbTint.rawValue),
        ("nd",             SDIPropCode.ndFilter.rawValue),
        ("ndvalue",        SDIPropCode.ndFilterValue.rawValue),
        ("framerate",      SDIPropCode.recordingFrameRate.rawValue),
    ]
    return nameMap.first(where: { lower.contains($0.0) })?.1
}

// MARK: - LUT commands

func runLUTList(host: String, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host)...")
        await backend.connect()

        for await state in backend.updates {
            switch state.connection {
            case .awaitingApproval:
                print("Waiting for pairing approval on camera...")
            case .connected:
                // Wait briefly for LUT names to arrive (fetched after initial state)
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                let rawNames = await backend.rawLUTNames
                if rawNames.isEmpty {
                    print("No LUT name data available (camera may not report display strings).")
                } else {
                    print("\nLUT Slots:")
                    for slot in 1...16 {
                        let slotValue = UInt16((0x01 << 8) | slot)
                        let raw = rawNames[slotValue]
                        let isEmpty = raw == nil || raw == "(No Import)" || raw?.hasSuffix("(No Import)") == true
                        let label: String
                        if isEmpty {
                            label = "(empty)"
                        } else {
                            // Strip "UserN:" prefix for cleaner display
                            label = raw.map { n -> String in
                                if n.hasPrefix("User"), let c = n.firstIndex(of: ":") {
                                    return String(n[n.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                                }
                                return n
                            } ?? "(empty)"
                        }
                        print(String(format: "  User%-2d (0x%04X)  %@", slot, slotValue, isEmpty ? label : "ok " + label))
                    }
                    let presets = rawNames.filter { $0.key & 0xFF00 == 0x0000 }.sorted { $0.key < $1.key }
                    if !presets.isEmpty {
                        print("\nPresets:")
                        for (value, name) in presets {
                            print(String(format: "  Preset%-2d (0x%04X)  %@", Int(value & 0xFF), value, name))
                        }
                    }
                }
                sema.signal(); return
            case .failed(let msg):
                fputs("Failed: \(msg)\n", stderr); sema.signal(); return
            case .fingerprintChanged(let observed):
                fputs("SSH host key \(observed) doesn't match the pinned fingerprint\n", stderr); sema.signal(); return
            default: break
            }
        }
    }
    waitServicingMain(sema)
}

func runLUTImport(host: String, cubePath: String, slot: Int, displayName: String?, recorder: (any TrafficRecorder)?) {
    // Read cube file
    guard let cubeData = FileManager.default.contents(atPath: cubePath) else {
        fputs("Cannot read file: \(cubePath)\n", stderr); exit(1)
    }

    // Validate LUT_3D_SIZE is present (basic sanity check; camera validates the rest)
    let cubeStr = String(data: cubeData.prefix(4096), encoding: .utf8) ?? ""
    if !cubeStr.contains("LUT_3D_SIZE") {
        print("Warning: LUT_3D_SIZE not found in first 4 KB — may not be a valid .cube file")
    }

    let baseName = (cubePath as NSString).lastPathComponent
    // The camera wants the .cube extension on the file name.
    let importFileName = displayName.map { n in n.hasSuffix(".cube") ? n : n + ".cube" } ?? baseName

    print("Importing \(baseName) -> User\(slot) as '\(importFileName)' (\(cubeData.count) bytes)...")

    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        await backend.connect()

        for await state in backend.updates {
            switch state.connection {
            case .awaitingApproval:
                print("Waiting for pairing approval on camera...")
            case .connected:
                do {
                    try await backend.importLUT(cubeData, fileName: importFileName, slot: slot)
                    print("Imported to User\(slot)")
                    let rawNames = await backend.rawLUTNames
                    let slotValue = UInt16((0x01 << 8) | slot)
                    let name = rawNames[slotValue] ?? importFileName
                    print("   Slot User\(slot) (0x\(String(format: "%04X", slotValue))): \(name)")
                } catch PTPError.lutImportPrecondition(let msg) {
                    fputs("Precondition failed: \(msg)\n", stderr)
                } catch PTPError.lutImportFailed(let result, let detail) {
                    // If camera rejects the name, retry with the original filename
                    if result == .ngInvalidName, displayName != nil {
                        print("Camera rejected name '\(importFileName)' — retrying with '\(baseName)'...")
                        do {
                            try await backend.importLUT(cubeData, fileName: baseName, slot: slot)
                            print("Imported to User\(slot) (fallback name '\(baseName)')")
                        } catch {
                            fputs("Retry failed: \(error)\n", stderr)
                        }
                    } else {
                        fputs("Import failed: \(detail)\n", stderr)
                    }
                } catch PTPError.timeout {
                    fputs("Timed out waiting for camera result (0xC214 not received within 30 s)\n", stderr)
                } catch {
                    fputs("\(error)\n", stderr)
                }
                sema.signal(); return
            case .failed(let msg):
                fputs("Failed: \(msg)\n", stderr); sema.signal(); return
            case .fingerprintChanged(let observed):
                fputs("SSH host key \(observed) doesn't match the pinned fingerprint\n", stderr); sema.signal(); return
            default: break
            }
        }
    }
    waitServicingMain(sema)
}

/// Live view check via GetObject(0xFFFFC002).
/// Sets D26A=Low, GetObjectInfo once, fetches `frameCount` frames, restores D26A, optionally saves the last frame.
func runLiveView(host: String, frameCount: Int, savePath: String?, recorder: (any TrafficRecorder)?) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        print("Connecting to \(host) for live view check...")
        await backend.connect()
        for await state in backend.updates {
            if case .failed(let msg) = state.connection {
                fputs("\(msg)\n", stderr); sema.signal(); return
            }
            guard state.connection == .connected else { continue }

            // Wait for 0xD221 Live View Status to be reported
            guard state.hasLiveView || !state.hasReported else {
                if state.hasReported {
                    print("0xD221 Live View Status not Enabled on this camera")
                    sema.signal(); return
                }
                continue
            }
            guard state.hasLiveView else { continue }

            let config = await backend.liveViewConfig
            if config.isStream {
                // An FX5: through the camera's own stream, to this Mac (CAMCTL_LIVEVIEW_QUALITY=high for 1080p).
                let quality: LiveViewQuality = ProcessInfo.processInfo.environment["CAMCTL_LIVEVIEW_QUALITY"] == "high" ? .high : .low
                print("No Live View Status: live view through the camera's stream (\(quality))")
                let started = Date()
                do {
                    try await backend.startLiveView(quality: quality)
                } catch {
                    fputs("start failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n", stderr)
                    await backend.stopLiveView(); sema.signal(); return
                }
                var got = 0
                var last: Data?
                for i in 1...frameCount {
                    do {
                        let jpeg = try await backend.liveViewFrame()
                        got += 1
                        last = jpeg
                        print("  picture \(i): \(jpeg.count) B JPEG at \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    } catch {
                        print("  picture \(i): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                    }
                }
                await backend.stopLiveView()
                print("\n\(got)/\(frameCount) pictures; stream stopped, the camera's destination given back")
                if let last, let path = savePath {
                    try? last.write(to: URL(fileURLWithPath: path))
                    print("   Saved: \(path)")
                }
                sema.signal(); return
            }
            print("0xD221 Live View Status = Enabled")

            // The link's quality and rate: Low at 1 fps over a network, High at 24 fps on USB
            await backend.setLiveViewQuality(config.quality)
            print("   0xD26A set to \(config.quality == .high ? "High" : "Low") quality, \(String(format: "%.0f", 1 / config.frameInterval)) fps")

            // GetObjectInfo once per session
            do {
                try await backend.fetchLiveViewObjectInfo()
                print("   GetObjectInfo(0xFFFFC002) OK")
            } catch {
                fputs("GetObjectInfo failed: \(error)\n", stderr)
                await backend.stopLiveView(); sema.signal(); return
            }

            var jpegSizes: [Int] = []
            var times: [TimeInterval] = []
            var lastFrame: Data?

            for i in 1...frameCount {
                let t0 = Date()
                do {
                    let frame = try await backend.liveViewFrame()
                    let elapsed = Date().timeIntervalSince(t0)
                    jpegSizes.append(frame.count)
                    times.append(elapsed)
                    lastFrame = frame
                    print("  frame \(i): \(frame.count) B JPEG, \(String(format: "%.0f", elapsed * 1000)) ms")
                } catch LiveViewError.noData {
                    print("  frame \(i): camera not ready (retry)")
                } catch {
                    print("  frame \(i): error: \(error)")
                }
                // The link's rate cap
                let elapsed = Date().timeIntervalSince(t0)
                let wait = config.frameInterval - elapsed
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }

            // Read wire bytes before stopLiveView resets the counter
            let wireTotal = await backend.liveViewWireBytes

            // Restore quality
            await backend.stopLiveView()
            print("   0xD26A restored")
            let avgJpeg  = jpegSizes.isEmpty ? 0 : jpegSizes.reduce(0, +) / jpegSizes.count
            let avgMs    = times.isEmpty ? 0.0 : times.reduce(0, +) / Double(times.count) * 1000.0
            let wirePerFrame = jpegSizes.isEmpty ? 0 : wireTotal / jpegSizes.count

            print("\nLive view summary (\(jpegSizes.count)/\(frameCount) frames):")
            print("   Avg JPEG size:        \(avgJpeg) B")
            print("   Avg wire bytes/frame: \(wirePerFrame) B  (protocol overhead included, both directions)")
            print("   Avg fetch time:       \(String(format: "%.0f", avgMs)) ms/frame")
            print("   Est. wire rate at 1 fps: \(wirePerFrame) B/s ~ \(String(format: "%.1f", Double(wirePerFrame) * 8 / 1000)) kbit/s")

            if let frame = lastFrame, let path = savePath {
                do {
                    try frame.write(to: URL(fileURLWithPath: path))
                    print("   Saved: \(path)")
                } catch {
                    fputs("Could not save frame: \(error)\n", stderr)
                }
            }
            sema.signal()
            return
        }
        fputs("Camera did not report live view status\n", stderr); sema.signal()
    }
    waitServicingMain(sema)
}

/// Press the camera's own buttons and turn its dials over the network (0xD309 / 0xD30B), recording what each step
/// does to its screen and properties. Steps run in order on one connection:
///   btn:<name|0xID>[:<hold s>]   dial:<0xID>:<notches>   wait:<s>
///   osd:<name>   saves <outDir>/<name>.png, the camera's on-screen display
///   lv:<name>    saves <outDir>/<name>.jpg, one live view frame (or says why there isn't one)
///   props:<name> saves <outDir>/<name>.txt and prints what changed since the last props step
///   title:<text>   camid:<A–Z>   reel:<n>   clip naming; naming prints it with the next clip's name
/// Only the playback keys are allowed. MOVIE, MENU, Fn, Mode, Delete and the custom buttons are refused: this is
/// for finding out how playback works, not for changing how the camera shoots.
func runKeys(host: String, outDir: String, steps: [String], recorder: (any TrafficRecorder)?) {
    let buttons: [String: UInt16] = ["up": 0x01, "down": 0x02, "left": 0x03, "right": 0x04, "enter": 0x05, "playback": 0x11]
    let dir = URL(fileURLWithPath: outDir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func code(_ c: UInt16) -> String { c == 0x2001 ? "OK" : String(format: "0x%04X", c) }
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        await backend.connect()
        for await state in backend.updates {
            if case .failed(let msg) = state.connection { fputs("\(msg)\n", stderr); exit(1) }
            if state.connection == .connected && state.hasReported { break }
        }
        let offered = await backend.emulatableButtons, dials = await backend.emulatableDials
        print("buttons: " + offered.map { String(format: "0x%02X", $0) }.joined(separator: " ")
              + "   dials: " + dials.map { String(format: "0x%04X", $0) }.joined(separator: " "))
        var lastProps: [UInt16: String] = [:]
        var liveViewStarted = false
        var stream: Task<Void, Never>?
        let t0 = Date()
        for step in steps {
            let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let stamp = String(format: "%6.1fs", Date().timeIntervalSince(t0))
            switch parts[0] {
            case "btn", "btn!":
                let name = parts.count > 1 ? parts[1].lowercased() : ""
                guard let id = buttons[name] ?? (name.hasPrefix("0x") ? UInt16(name.dropFirst(2), radix: 16) : nil),
                      buttons.values.contains(id) else { print("\(stamp) \(step): refused (not a playback key)"); continue }
                guard offered.contains(id) else { print("\(stamp) \(step): the camera doesn't offer this button"); continue }
                // In Record mode the arrows and ENTER are the camera's shooting shortcuts (on FX3: Right toggles
                // peaking, Left zebras), so they're only pressed in Playback (0xD0BC = 0x02). btn! overrides that,
                // for putting a shortcut back the way it was.
                if id != 0x11 && parts[0] == "btn" {
                    await backend.refreshProperties()
                    let mode = await backend.rawProperties[0xD0BC]?.currentUInt8()
                    guard mode == 0x02 else {
                        print("\(stamp) \(step): refused, the camera isn't in Playback (0xD0BC = \(mode.map { String($0) } ?? "—"))"); continue
                    }
                }
                let hold = parts.count > 2 ? Double(parts[2]) ?? 0.1 : 0.1
                print("\(stamp) \(step): \(code(await backend.pressCameraButton(id, holdFor: hold)))")
            case "key", "mkey":
                // Any button the camera offers, in any mode: key:0x1D Home, key:0x22 Back, key:0x07–0x0B the multi
                // selector (0xD208 list, Camera Button Function); mkey:0x06:1.5 holds MENU (0xD209 list, the Multi one).
                guard parts.count > 1, let id = UInt16(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { print("\(stamp) \(step): key:<id>[:hold]"); continue }
                let hold = parts.count > 2 ? Double(parts[2]) ?? 0.1 : 0.1
                if parts[0] == "key" {
                    guard offered.contains(id) else { print("\(stamp) \(step): the camera doesn't offer this button"); continue }
                    print("\(stamp) \(step): \(code(await backend.pressCameraButton(id, holdFor: hold)))")
                } else {
                    print("\(stamp) \(step): \(code(await backend.pressCameraButtonMulti(id, holdFor: hold)))")
                }
            case "state":
                // What the app would show now, from the camera's change events alone (no refresh here).
                let s = await backend.currentState
                let mode = await backend.rawProperties[0xD0BC]?.currentUInt8()
                print("\(stamp) state: mode \(mode.map { String($0) } ?? "—"), playing \(s.playback?.isPlaying.map(String.init) ?? "—")"
                      + ", review \(s.playback?.inReview.map(String.init) ?? "—"), REC \(s.recording.state)"
                      + ", WB \(s.whiteBalance.map { "\($0.preset.shown) \(Int($0.kelvin.value))K" } ?? "—")"
                      + ", ND \(s.nd?.preset.shown ?? "—") \(s.ndMode?.shown ?? "—"), tally \(s.tally?.shown ?? "—")"
                      + ", call \(s.call.map { String($0.shown) } ?? "—"), gamut \(s.colorGamut?.shown ?? "—")"
                      + ", buttons \(s.cameraButtons.map(\.rawValue).joined(separator: ","))")
            case "afstate":
                // The Autofocus tile and AF Settings window as the app reads them now, with SteadyShot and Imager Mode.
                let s = await backend.currentState
                func c<V>(_ choice: Choice<V>?) -> String {
                    choice.map { "\($0.shown)\($0.isWritable ? "" : " ro") [\($0.options.map { "\($0)" }.joined(separator: ", "))]" } ?? "—"
                }
                print("\(stamp) afstate: AF/MF \(c(s.focusMode)), autofocusing \(s.focusIsAuto), push \(s.canAutoFocus ? (s.canPushAutoFocus ? "live" : "greyed") : "none")"
                      + "\n    subject \(c(s.subjectRecognition))\n    area \(c(s.focusArea))"
                      + "\n    transition \(c(s.afTransitionSpeed)), shift \(c(s.afSubjectShift)), assist \(c(s.afAssist))"
                      + "\n    SteadyShot \(c(s.steadyShot))\n    imager \(c(s.imagerMode))"
                      + "\n    focus \(s.focusDrive.map { "\($0.position.map { String(format: "%.3f", $0) } ?? "—") \($0.distance.map { "\($0) m" } ?? "—")" } ?? "—")")
            case "strings":
                // A display string list by its type (SDIO_GetDisplayStringList): strings:0x0A the assignable
                // buttons' functions, 0x0B their short names, 0x05 scene files.
                guard parts.count > 1, let type = UInt32(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { print("\(stamp) \(step): strings:<type>"); continue }
                let strings = await backend.displayStrings(type: type) ?? [:]
                print("\(stamp) \(step): \(strings.count) — " + strings.keys.sorted()
                    .map { String(format: "0x%02X ", $0) + (strings[$0] ?? "") }.joined(separator: " · "))
            case "focusto":
                // Drives the focus back to a Follow Focus Position (0xE089) in short slow bursts, each read back: for
                // putting a lens back after a test. Gives up after 15 s.
                guard parts.count > 1, let target = Int(parts[1]) else { print("\(stamp) \(step): focusto:<0–65535>"); continue }
                let began = Date()
                var now = -1
                while Date().timeIntervalSince(began) < 15 {
                    await backend.refreshProperties()
                    now = Int(await backend.rawProperties[SDIPropCode.followFocusPosition.rawValue]?.currentUInt16() ?? 0)
                    if abs(now - target) <= 8 { break }
                    // +1 moved it down (10217 → 10182) on the FX6.
                    _ = await backend.stepControl(.focusOperation, by: now > target ? 1 : -1)
                    try? await Task.sleep(nanoseconds: abs(now - target) > 300 ? 250_000_000 : 40_000_000)
                    _ = await backend.stepControl(.focusOperation, by: 0)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                print("\(stamp) \(step): at \(now)" + (abs(now - target) <= 8 ? "" : " (gave up)"))
            case "ctl":
                // A step control through ControlDevice: ctl:focus:-1, ctl:zoom:1, ctl:kelvin:1, ctl:tint:-3, ctl:ecs:1.
                let controls: [String: SDIControlCode] = ["focus": .focusOperation, "zoom": .zoomOperation,
                                                          "kelvin": .colorTempStep, "tint": .wbTintStep, "ecs": .shutterECSStep]
                guard parts.count > 2, let c = controls[parts[1]], let n = Int(parts[2]) else {
                    print("\(stamp) \(step): ctl:focus|zoom|kelvin|tint|ecs:<steps>"); continue
                }
                print("\(stamp) \(step): \(code(await backend.stepControl(c, by: n)))")
            case "tiles":
                // Every tile's value as the app would show it now, from the camera's change events alone; "ro" marks
                // one the camera won't take a change to.
                let s = await backend.currentState
                func c<V>(_ x: Choice<V>?) -> String { x.map { "\($0.value)" + ($0.isWritable ? "" : " ro") } ?? "—" }
                func l(_ x: Level?) -> String { x.map { String(format: "%g", $0.value) + ($0.isWritable ? "" : " ro") } ?? "—" }
                let battery = s.batteryPercent.map { "\($0)%" } ?? s.batteryVolts.map { String(format: "%.1f V", $0) } ?? "—"
                print("\(stamp) tiles: REC \(s.recording.state), ISO \(c(s.iso)), base \(c(s.baseISO)), shutter "
                      + "\(c(s.shutterMode)) \(c(s.shutterAngle))° \(c(s.shutterSpeed)), fps \(c(s.frameRate?.project)), "
                      + "\(s.frameRate?.variableName ?? "S&Q") \(c(s.frameRate?.variable)) \(c(s.frameRate?.variableRate)), "
                      + "ND \(c(s.nd?.preset)) \(c(s.ndMode)), WB \(c(s.whiteBalance?.preset)) \(l(s.whiteBalance?.kelvin))K "
                      + "tint \(l(s.whiteBalance?.tint)), iris \(c(s.iris)), LUT \(c(s.lut)), desqueeze \(c(s.desqueeze)), "
                      + "codec \(c(s.fileFormat)), res \(c(s.resolution)), gamut \(c(s.colorGamut)), "
                      + "media \(s.mediaRemainingMinutes.map { "\($0) min" } ?? "—"), battery \(battery), clip \(s.clipName ?? "—")")
                if SonyProBody.has(s.model) {
                    let outputs = s.monitoring?.outputs.map { "\($0.name) \($0.overlays[.lut].map { c($0) } ?? "—")" } ?? []
                    let lens = s.focusDrive.map { "focus \($0.position.map { String(format: "%.3f", $0) } ?? "—") "
                        + "\($0.distance.map { "\($0) m" } ?? "—") max \($0.maxSpeed)" } ?? "focus —"
                    print("\(stamp) fx6: mode \(c(s.shootingMode)), gain \(c(s.gain)) base \(c(s.baseSensitivity)), LUT \(c(s.look)) [\(outputs.joined(separator: ", "))]"
                          + ", in rec \(c(s.recordedLUT)), proxy \(c(s.proxyRecording)) \(s.proxyStatus ?? ""), ECS "
                          + "\(s.ecs.map { "\(c($0.on)) \($0.frequency.map { String($0) } ?? "—") step \($0.canStep)" } ?? "—")"
                          + ", iris auto \(c(s.irisAuto)), ND auto \(c(s.ndAuto)), ISO auto \(c(s.isoAuto))"
                          + ", \(s.focalLength.map { "\($0) mm" } ?? "—"), \(lens), zoom "
                          + "\(s.zoomDrive.map { "max \($0.maxSpeed)" } ?? "—"), speed \(s.playback?.speed.map { String($0) } ?? "—")")
                    print("\(stamp) buttons: " + s.assignableButtons.map {
                        "\($0.name) \($0.function)\($0.isOn == true ? " ON" : "")\($0.isPressable ? " ✓" : "")"
                    }.joined(separator: " · "))
                }
            case "set":
                // Raw write at the property's own size, little-endian: set:0xD010:0x01. Debugging only.
                guard parts.count > 2, let c = UInt16(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16),
                      let v = UInt64(parts[2].replacingOccurrences(of: "0x", with: ""), radix: 16)
                else { print("\(stamp) \(step): set:<code>:<hex value>"); continue }
                let size = max(await backend.rawProperties[c]?.dataType.byteSize ?? 1, 1)
                var bytes = Data(), rest = v
                for _ in 0..<size { bytes.append(UInt8(rest & 0xFF)); rest >>= 8 }
                print("\(stamp) \(step): \(code(await backend.setRawProperty(c, data: bytes)))")
            case "dial":
                guard parts.count > 2, let id = UInt16(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16),
                      let n = Int16(parts[2]), dials.contains(id) else { print("\(stamp) \(step): bad or unoffered dial"); continue }
                print("\(stamp) \(step): \(code(await backend.turnCameraDial(id, notches: n)))")
            case "cmd":
                // The app's own path: a playback command through SonyCameraBackend, gate and all.
                let commands: [String: PlaybackCommand] = ["review": .review, "live": .live, "toggle": .togglePlay,
                                                           "ff": .fastForward, "rew": .rewind,
                                                           "scanf": .scan(forward: true), "scanb": .scan(forward: false),
                                                           "endscan": .endScan, "next": .next, "prev": .previous,
                                                           "stop": .stop, "recreview": .recReview]
                guard parts.count > 1, let command = commands[parts[1]] else { print("\(stamp) \(step): unknown command"); continue }
                let began = Date()
                await backend.send(.playback(command))
                await backend.refreshProperties()
                let mode = await backend.rawProperties[0xD0BC]?.currentUInt8()
                print("\(stamp) \(step): done in \(String(format: "%.2fs", Date().timeIntervalSince(began))), mode \(mode.map { String($0) } ?? "—")")
            case "app":
                // Any of the app's commands below, through SonyCameraBackend as a tile sends it: app:tally:Red,
                // app:call:on, app:ndmode:Variable, app:gamut:S-Gamut3, app:wb:AWB, app:nd:0.9, app:button:home,
                // app:baseiso:12800, app:kelvin:5600, app:shuttermode:speed, app:vnd:0.9, app:sq:on, app:sqrate:30,
                // app:desqueeze:2.0x, app:lut:s709, app:fps:25, app:codec:XAVC L, app:res:1920x1080.
                guard parts.count > 2 else { print("\(stamp) \(step): app:<what>:<value>"); continue }
                let value = parts[2...].joined(separator: ":")
                let command: CameraCommand? = switch parts[1] {
                case "tally": .setTally(value)
                case "call": .setCall(value == "on")
                case "ndmode": .setNDMode(value)
                case "gamut": .setColorGamut(value)
                case "wb": .setWhiteBalancePreset(value)
                case "nd": .setNDPreset(value)
                case "button": CameraBodyButton(rawValue: value).map { .pressCameraButton($0) }
                case "baseiso": Int(value).map { .setBaseISO($0) }
                case "kelvin": Double(value).map { .setKelvin($0) }
                case "shuttermode": ShutterMode(rawValue: value).map { .setShutterMode($0) }
                case "vnd": Double(value).map { .setVariableND($0) }
                case "sq": .setFrameRateVariable(value == "on")
                case "sqrate": Double(value).map { .setFrameRateVariableRate($0) }
                case "desqueeze": .setDesqueeze(value)
                case "lut": .setLUT(value)
                case "fps": .setFrameRate(value)
                case "codec": .setFileFormat(value)
                case "res": .setResolution(value)
                case "iris": Double(value).map { .setIris($0) }
                // An FX6's (docs/fx6-controls.md)
                case "shootingmode": .setShootingMode(value)
                case "gain": Int(value).map { .setGain($0) }
                case "basesens": .setBaseSensitivity(value)
                case "steadyshot": .setSteadyShot(value)
                case "imager": .setImagerMode(value)
                case "af": .autoFocus
                case "afmode": .setFocusMode(value)
                case "subject": .setSubjectRecognition(value.replacingOccurrences(of: "_", with: " "))
                case "area": .setFocusArea(value.replacingOccurrences(of: "_", with: " "))
                case "afspeed": Int(value).map { .setAFTransitionSpeed($0) }
                case "afshift": Int(value).map { .setAFSubjectShift($0) }
                case "afassist": .setAFAssist(value == "on")
                case "falsecolor": .setFalseColor(value == "on")
                case "reclut": .setRecordedLUT(value == "on")
                case "proxy": .setProxyRecording(value == "on")
                case "ecs": .setECS(value == "on")
                case "ecsstep": Int(value).map { .stepECS($0) }
                case "irisauto": .setIrisAuto(value == "on")
                case "ndauto": .setNDAuto(value == "on")
                case "isoauto": .setISOAuto(value == "on")
                case "look": .setLook(value == "on")
                case "lutout":
                    // app:lutout:LUT1:off
                    value.split(separator: ":").count == 2
                        ? .setMonitorOverlay(.lut, value.hasSuffix("on"), output: String(value.split(separator: ":")[0])) : nil
                case "focus": Int(value).map { .driveFocus($0) }
                case "zoom": Int(value).map { .driveZoom($0) }
                case "assign": Int(value).map { .pressAssignable($0) }
                default: nil
                }
                guard let command else { print("\(stamp) \(step): unknown"); continue }
                let began = Date()
                await backend.send(command)
                print("\(stamp) \(step): sent in \(String(format: "%.2fs", Date().timeIntervalSince(began)))")
            case "modewait":
                // Poll Camera Operating Mode (0xD0BC: 1 Record, 2 Playback) until it changes, or give up.
                let limit = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
                await backend.refreshProperties()
                let start = await backend.rawProperties[0xD0BC]?.currentUInt8()
                let began = Date()
                var now = start
                while now == start && Date().timeIntervalSince(began) < limit {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await backend.refreshProperties()
                    now = await backend.rawProperties[0xD0BC]?.currentUInt8()
                }
                let took = String(format: "%.2fs", Date().timeIntervalSince(began))
                print("\(stamp) \(step): mode \(start.map { String($0) } ?? "—") → \(now.map { String($0) } ?? "—")"
                      + (now == start ? " (no change in \(took))" : " after \(took)"))
            case "iso":
                guard parts.count > 1, let v = Int(parts[1]) else { print("\(stamp) \(step): iso needs a number"); continue }
                await backend.send(.setISO(v))
                print("\(stamp) \(step): sent")
            case "tint":
                guard parts.count > 1, let v = Double(parts[1]) else { print("\(stamp) \(step): tint needs a number"); continue }
                await backend.send(.setTint(v))
                print("\(stamp) \(step): sent")
            case "angle":
                guard parts.count > 1, let v = Double(parts[1]) else { print("\(stamp) \(step): angle needs a number"); continue }
                await backend.send(.setShutterAngle(v))
                print("\(stamp) \(step): sent")
            case "speed":
                guard parts.count > 1 else { print("\(stamp) \(step): speed needs a label like 1/48"); continue }
                await backend.send(.setShutterSpeed(parts[1]))
                print("\(stamp) \(step): sent")
            case "title":
                await backend.send(.setClipTitle(parts.dropFirst().joined(separator: ":")))
                print("\(stamp) \(step): sent")
            case "camid":
                guard parts.count > 1 else { print("\(stamp) \(step): camid needs a letter"); continue }
                await backend.send(.setClipCameraID(parts[1]))
                print("\(stamp) \(step): sent")
            case "reel":
                guard parts.count > 1, let v = Int(parts[1]) else { print("\(stamp) \(step): reel needs a number"); continue }
                await backend.send(.setClipReel(v))
                print("\(stamp) \(step): sent")
            case "naming":
                let s = await backend.currentState
                let n = s.fileNaming
                print("\(stamp) naming: next clip \(s.clipName ?? "—") · title \(n?.title.map { "\"\($0.value)\"" } ?? "—")"
                      + " · camera ID \(n?.cameraID?.value ?? "—") · reel \(n?.reel.map { String(Int($0.value)) } ?? "—")"
                      + (n?.failure.map { " · REFUSED: \($0)" } ?? ""))
            case "rec":
                guard parts.count > 1, ["start", "stop"].contains(parts[1]) else { print("\(stamp) \(step): rec:start|stop"); continue }
                await backend.send(.record(parts[1] == "start"))
                print("\(stamp) \(step): sent")
            case "wait":
                let secs = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            case "osd":
                do {
                    let png = try await backend.osdImage()
                    try png.write(to: dir.appendingPathComponent("\(parts[1]).png"))
                    print("\(stamp) \(step): \(png.count) B")
                } catch { print("\(stamp) \(step): error: \(error)") }
            case "lvstream":
                // Pull frames in the background, as the app's Live View tile does, until lvstop.
                if !liveViewStarted {
                    await backend.setLiveViewQuality(.low)
                    do { try await backend.fetchLiveViewObjectInfo(); liveViewStarted = true }
                    catch { print("\(stamp) \(step): live view error: \(error)"); continue }
                }
                stream?.cancel()
                stream = Task {
                    var frames = 0
                    while !Task.isCancelled {
                        if (try? await backend.liveViewFrame()) != nil { frames += 1 }
                    }
                    print("  (streamed \(frames) frames)")
                }
                print("\(stamp) \(step): streaming")
            case "lvq":
                // Live View Image Quality (0xD26A): put it back after lv/lvstream set it low.
                guard parts.count > 1, ["high", "low"].contains(parts[1]) else { print("\(stamp) \(step): lvq:high|low"); continue }
                await backend.setLiveViewQuality(parts[1] == "high" ? .high : .low)
                print("\(stamp) \(step): sent")
            case "lvstop":
                stream?.cancel()
                await stream?.value
                stream = nil
            case "lv":
                if !liveViewStarted {
                    await backend.setLiveViewQuality(.low)
                    do { try await backend.fetchLiveViewObjectInfo(); liveViewStarted = true }
                    catch { print("\(stamp) \(step): live view error: \(error)"); continue }
                }
                var saved = false
                for _ in 0..<4 where !saved {
                    do {
                        let jpeg = try await backend.liveViewFrame()
                        try jpeg.write(to: dir.appendingPathComponent("\(parts[1]).jpg"))
                        print("\(stamp) \(step): \(jpeg.count) B"); saved = true
                    } catch LiveViewError.noData {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    } catch { print("\(stamp) \(step): error: \(error)"); break }
                }
                if !saved { print("\(stamp) \(step): no frame") }
            case "props":
                await backend.refreshProperties()
                let props = await backend.rawProperties
                var now: [UInt16: String] = [:]
                for (c, p) in props {
                    now[c] = "\(p.isEnabled) " + p.currentValue.map { String(format: "%02X", $0) }.joined()
                }
                let text = now.keys.sorted().map { String(format: "0x%04X ", $0) + now[$0]! }.joined(separator: "\n")
                try? text.write(to: dir.appendingPathComponent("\(parts[1]).txt"), atomically: true, encoding: .utf8)
                if lastProps.isEmpty {
                    print("\(stamp) \(step): \(now.count) properties")
                } else {
                    let changed = Set(now.keys).union(lastProps.keys).filter { now[$0] != lastProps[$0] }.sorted()
                    print("\(stamp) \(step): \(changed.count) changed" + (changed.isEmpty ? "" : ": ")
                          + changed.prefix(24).map { String(format: "0x%04X ", $0) + "\(lastProps[$0] ?? "—") → \(now[$0] ?? "—")" }
                              .joined(separator: ", "))
                }
                lastProps = now
            default:
                print("\(stamp) \(step): unknown step")
            }
            fflush(stdout)
        }
        if liveViewStarted { await backend.stopLiveView() }
        await backend.stopOSDImage()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await backend.disconnect()
        sema.signal()
    }
    waitServicingMain(sema)
}

// MARK: - HaLow field check

/// Finds the HaLow nodes the way the app does (Bonjour, the gateway, each node's list of the mesh), plus any addresses
/// given, polls each once, then lists the mesh's devices. Login: CAMCTL_NODE_USER (default root), CAMCTL_NODE_PASSWORD.
func runHaLow(addresses: [String]) {
    let env = ProcessInfo.processInfo.environment
    let password = env["CAMCTL_NODE_PASSWORD"] ?? ""
    if password.isEmpty { print("CAMCTL_NODE_PASSWORD not set: nodes are looked for, not logged into") }
    let credentials = InMemoryCredentialStore()
    credentials.setPassword(password.isEmpty ? nil : password, for: haLowPasswordID)
    let settings = HaLowSettings(displayMode: .on, manualAddresses: addresses, username: env["CAMCTL_NODE_USER"] ?? "root")
    let monitor = HaLowMonitor(settings: settings, credentialStore: credentials,
                               localPollInterval: 3600, remotePollInterval: 3600)
    let sema = DispatchSemaphore(value: 0)
    Task {
        let started = Date()
        await monitor.findNodes()
        let nodes = await monitor.currentNodes()
        print("\nHaLow nodes (\(String(format: "%.1f", Date().timeIntervalSince(started))) s):")
        if nodes.isEmpty { print("  (none)") }
        for node in nodes {
            let tags = [node.isManual ? "added" : "found", node.isLocal ? "this device's" : nil].compactMap { $0 }
            print("  \(node.name)  \(node.address)  \(tags.joined(separator: ", "))  \(node.state?.label ?? "not polled")")
            guard let stats = node.stats else { continue }
            if let sig = stats.signalDBm {
                print("    signal:    \(sig) dBm")
                if let noise = stats.noiseDBm { print("    noise:     \(noise) dBm  SNR \(sig - noise) dB") }
                if let rate = stats.phyRateKbps { print("    PHY rate:  \(rate) kbit/s") }
                if let mcs = stats.mcsIndex { print("    MCS:       \(mcs)") }
                if let mhz = stats.channelWidthMHz { print("    width:     \(mhz) MHz") }
            } else {
                print("    no HaLow peer (link down)")
            }
        }

        let scan = await monitor.meshDevices()
        print("\nMesh devices:")
        if scan.devices.isEmpty && scan.problems.isEmpty { print("  (none)") }
        for device in scan.devices {
            var parts: [String] = [device.ip, device.name ?? "—", device.mac.isEmpty ? "—" : device.mac]
            if let node = device.node { parts.append("via \(node)") }
            if let maker = device.cameraMaker { parts.append("\(maker.label) camera") }
            parts.append(device.isPresent ? "present" : "not on the mesh")
            print("  " + parts.joined(separator: "  "))
        }
        for (address, problem) in scan.problems.sorted(by: { $0.key < $1.key }) { print("  \(address): \(problem)") }
        print("")
        sema.signal()
    }
    waitServicingMain(sema)
}

func printUsage() {
    print("""
    camctl -- Sony PTP-IP camera control

    Usage:
      camctl [--record <file>] connect  <host>                         Connect and show camera info
      camctl [--record <file>] dump     <host>                         Dump all properties (decoded + raw hex)
      camctl [--record <file>] set      <host> <prop> <value>          Set a property
      camctl [--record <file>] rec      <host> start|stop              Control recording
      camctl [--record <file>] lut list <host>                         List LUT slots (User1-16 + presets)
      camctl [--record <file>] lut import <host> <file.cube> --slot N [--name "Display Name"]
                                                                       Import a .cube file into a User slot
      camctl [--record <file>] liveview <host> [frames] [save.jpg]     Fetch live view frames, report bandwidth
      camctl [--record <file>] keys     <host> <dir> <step>...         Steps through the app's backend, one connection
                                        steps: btn:playback|enter|left|right, btn!:... (in Record mode too),
                                               dial:0x4001:<n>, wait:<s>, modewait:<s>,
                                               cmd:review|live|toggle|ff|rew|scanf|scanb|endscan|next|prev (the app's
                                               playback path), lvstream / lvstop, lvq:high|low,
                                               iso:<n>, tint:<n>, angle:<deg>, speed:<1/n>, rec:start|stop (Record mode),
                                               app:<what>:<value> (any tile's command: wb, kelvin, nd, ndmode, vnd,
                                               shuttermode, sq, sqrate, baseiso, desqueeze, lut, gamut, tally, call, …),
                                               tiles (every tile's value), state, osd:<name>, lv:<name>, props:<name>,
                                               key:<id>[:hold] (any 0xD208 button, any mode), mkey:<id>[:hold] (0xD209),
                                               set:<code>:<hex> (raw write to a property the camera lists, debugging)
      camctl usb                                                       List Sony cameras on USB; use usb:<serial> as <host>
      camctl find [seconds]                                            Cameras on this Mac's networks (Sony, Blackmagic)
      camctl halow [node-ip...]                                        Find HaLow nodes (plus any given), poll once,
                                                                       list the mesh's devices
      camctl bm <host> [--https] state | watch <s>                     A Blackmagic camera through the app's backend:
      camctl bm <host> [--https] set <name> <value>                    what it reads, and what a control does to it
      camctl probe <host>                                              What an address answers as (ARRI, VENICE, Sony)
      camctl venice <host> [--dump] [--get/--set/--keys]               A VENICE through the app's Savona backend
                                                                       (password: CAMCTL_VENICE_PASSWORD, or -p PASS)
      camctl arri <host> [--dump] [--get N] [--set N=V] [--call C]     An ARRI Web Remote through the app's backend;
      camctl arri --from <capture dir> [--dump]                        or what Tiles reads from a capture of one
                                                                       (iso, angle, speed, kelvin, tint, iris, nd, ndvar,
                                                                       fps, res, format, setting, lut, falsecolor, bars,
                                                                       focus, wb); rec start|stop; play <cmd>

    <prop>: hex code (0xD00E) or name fragment (shutterangle, iso, kelvin, tint, nd, framerate)
    --record <file>: capture raw PTP-IP traffic to a newline-delimited JSON file

    Access Authentication: set CAMCTL_SSH_USER and CAMCTL_SSH_PASSWORD; optionally CAMCTL_SSH_FINGERPRINT.
    HaLow nodes: CAMCTL_NODE_PASSWORD (and CAMCTL_NODE_USER, default root).
    When waiting for pairing approval: navigate to Pairing on the camera and approve 'camctl'.
    """)
}

/// Sends one command the way the app does (CameraCommand through SonyCameraBackend), waits for the camera to
/// settle, and prints what it then reports. For checking command logic live, not just raw property writes.
func runSend(host: String, name: String, value: String, recorder: (any TrafficRecorder)?) {
    let command: CameraCommand
    switch name.lowercased() {
    case "iso": guard let v = Int(value) else { fputs("iso needs a number\n", stderr); exit(1) }; command = .setISO(v)
    case "baseiso": guard let v = Int(value) else { fputs("baseiso needs a number\n", stderr); exit(1) }; command = .setBaseISO(v)
    case "kelvin": guard let v = Double(value) else { fputs("kelvin needs a number\n", stderr); exit(1) }; command = .setKelvin(v)
    case "tint": guard let v = Double(value) else { fputs("tint needs a number\n", stderr); exit(1) }; command = .setTint(v)
    default: fputs("Unknown command \(name) (iso, baseiso, kelvin, tint)\n", stderr); exit(1)
    }
    final class Latest: @unchecked Sendable { var state: CameraState? }
    let latest = Latest()
    let sema = DispatchSemaphore(value: 0)
    Task {
        let backend = makeSonyBackend(host: host, recorder: recorder)
        await backend.connect()
        var sent = false
        for await state in backend.updates {
            latest.state = state
            if case .failed(let msg) = state.connection { fputs("Failed: \(msg)\n", stderr); sema.signal(); return }
            // Wait for the base ISO names too (fetched after the first property read), as the app would have them.
            guard !sent, state.connection == .connected, state.iso != nil, state.baseISO != nil else { continue }
            sent = true
            Task {
                await backend.send(command)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let after = latest.state ?? state
                print("ISO \(after.iso.map { String($0.value) } ?? "—"), base \(after.baseISO.map { String($0.value) } ?? "—"), "
                      + "WB \(after.whiteBalance.map { "\(Int($0.kelvin.value))K" } ?? "—"), "
                      + "tint \(after.whiteBalance?.tint.map { String($0.value) } ?? "—")")
                fflush(stdout)
                sema.signal()
            }
        }
    }
    waitServicingMain(sema)
}

// MARK: - venice: the Savona API from the command line (against a real body, or scripts/venice/mock_venice.py)

@MainActor
enum VeniceCLI {
    static func run(_ args: ArraySlice<String>) async {
        var host: String?
        var user = "admin"
        // From the environment by default: `ps` shows a -p to anyone on the machine.
        var password: String? = ProcessInfo.processInfo.environment["CAMCTL_VENICE_PASSWORD"]
        var gets: [String] = []
        var sets: [String] = []
        var keys: [String] = []
        var calls: [(String, String)] = []
        var commands: [String] = []
        var dump = false
        var listen: Double = 0
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "-u": user = it.next() ?? user
            case "-p": password = it.next()
            case "--get": gets.append(it.next() ?? "")
            case "--set": sets.append(it.next() ?? "")
            case "--keys": keys.append(it.next() ?? "")
            case "--call": if let m = it.next() { calls.append((m, it.next() ?? "[]")) }
            case "--send": commands.append(it.next() ?? "")
            case "--dump": dump = true
            case "--listen": listen = Double(it.next() ?? "3") ?? 3
            default: if host == nil { host = arg }
            }
        }
        guard let host else {
            print("camctl venice HOST [-u admin] [-p PASS] [--get Name] [--set Name=json] [--keys Rec] [--send lut=NAME|look=on|"
                  + "desqueeze=1.6x|falsecolor=on|falsecolor:Monitor=on|bars=on|iso=1600] [--dump] [--listen s]\n"
                  + "  the password from CAMCTL_VENICE_PASSWORD, which `ps` doesn't show, unless -p gives one")
            exit(2)
        }
        let backend = VeniceCameraBackend(host: host, user: user, password: password)
        let task = Task { await backend.connect() }
        var connected = CameraState()
        for await state in backend.updates {
            if state.connection == .connected { connected = state; break }
            if case .failed(let why) = state.connection {
                print("connect failed: \(why)")
                task.cancel()
                exit(1)
            }
        }
        // What Tiles would show for this camera: the backend's own reading, field by field.
        func show(_ label: String, _ value: Any?) { print("  \(label): \(value.map { "\($0)" } ?? "—")") }
        func choice<T>(_ c: Choice<T>?) -> String? {
            c.map { "\($0.shown)\($0.isWritable ? "" : " (locked)") of \($0.options.count)" }
        }
        func report(_ s: CameraState) {
            show("model", s.modelName.map { "\($0) (\(s.model ?? "?"))" })
            show("REC", s.recording.state)
            show("EI", choice(s.iso))
            show("base ISO", choice(s.baseISO))
            show("shutter", s.shutterMode.map { "\($0.value) angle \(s.shutterAngle?.value ?? 0) speed \(s.shutterSpeed?.value ?? "—")" })
            show("ND", choice(s.nd?.preset))
            show("WB", s.whiteBalance.map { "\(Int($0.kelvin.shown))K tint \($0.tint?.shown ?? 0)" })
            show("S&Q", s.frameRate.map { "\($0.variable?.shown ?? false) at \($0.variableRate?.shown ?? 0)" })
            show("project rate", choice(s.frameRate?.project))
            show("imager", choice(s.resolution))
            show("codec", choice(s.fileFormat))
            show("de-squeeze", s.desqueeze.map { "\($0.shown) of \($0.options.joined(separator: " "))\($0.isWritable ? "" : " (locked)")" })
            show("LUT", s.lut.map { "\($0.shown), \($0.options.count) looks: \($0.options.joined(separator: " | "))" })
            show("LUT on every output", s.look?.shown)
            for output in s.monitoring?.outputs ?? [] {
                let overlays = output.overlays.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value.shown ? "on" : "off")\($0.value.isWritable ? "" : "!")" }
                let leader = output.follows.map { id in s.monitoring?.outputs.first { $0.id == id }?.name ?? id }
                show("  \(output.name)", overlays.joined(separator: " ") + (leader.map { "  (same as \($0))" } ?? ""))
            }
            show("false colour", s.falseColor?.shown)
            show("sensor flip", choice(s.imageFlip))
            show("colour bars", choice(s.colorBars))
            show("playback", s.playback.map { "clip \($0.clipNumber ?? 0)/\($0.clipCount ?? 0) reviewing \($0.inReview.map { "\($0)" } ?? "?")" })
            show("clip", s.clipName)
            show("naming", s.fileNaming.map { "\($0.cameraID?.shown ?? "?") reel \(Int($0.reel?.shown ?? 0)) position \($0.position?.shown ?? "?")" })
            show("time display", s.timecodeShowsDuration.map { $0.shown ? "duration" : "timecode" })
            show("battery", s.batteryVolts.map { "\($0) V" } ?? s.batteryPercent.map { "\($0) %" })
            show("latency", s.latencyMilliseconds.map { "\($0) ms" })
        }
        print("Tiles reads it as:")
        report(connected)
        defer { task.cancel() }
        // Commands through the backend, as a tile sends them, then what Tiles shows after.
        if !commands.isEmpty {
            let latest = VeniceCLI.Latest(connected)
            let watching = Task { for await state in backend.updates { latest.state = state } }
            for line in commands {
                guard let command = VeniceCLI.command(line) else { print("? \(line)"); continue }
                print("send \(line)")
                await backend.send(command)
                try? await Task.sleep(for: .seconds(1.5))
            }
            print("Tiles reads it as, after:")
            report(latest.state)
            watching.cancel()
        }
        for name in gets {
            let values = (try? await VeniceCLI.client(of: backend)?.get([name])) ?? nil
            print("\(name) = \(String(describing: values?[name]?.description))")
        }
        for pair in sets {
            let bits = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { continue }
            guard !MediaSafety.refuses(pair) else { print(MediaSafety.refusal(pair)); continue }
            let value: MPValue
            if let i = Int64(bits[1]) { value = .int(i) }
            else if let d = Double(bits[1]) { value = .double(d) }
            else if bits[1] == "true" || bits[1] == "false" { value = .bool(bits[1] == "true") }
            else { value = .string(bits[1]) }
            try? await VeniceCLI.client(of: backend)?.set(bits[0], value)
            print("set \(bits[0]) = \(value)")
        }
        for key in keys {
            guard !MediaSafety.refuses(key) else { print(MediaSafety.refusal(key)); continue }
            try? await VeniceCLI.client(of: backend)?.sendKey(key)
            print("key \(key)")
        }
        for (method, paramsJSON) in calls {
            guard !MediaSafety.refuses(method + " " + paramsJSON) else {
                print(MediaSafety.refusal(method + " " + paramsJSON))
                continue
            }
            if let data = paramsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let value = VeniceCLI.mp(obj) {
                let result = try? await VeniceCLI.client(of: backend)?.request(method, value, timeout: 10)
                print("\(method) → \(result?.description ?? "nil")")
            }
        }
        if dump {
            let names = (try? await VeniceCLI.client(of: backend)?.propertyNames()) ?? []
            print("\(names.count) properties")
            var all: [String: MPValue] = [:]
            for chunk in names.chunked(into: 20) {
                if let answered = try? await VeniceCLI.client(of: backend)?.get(chunk, timeout: 15) { all.merge(answered) { _, n in n } }
            }
            for name in all.keys.sorted() { print("  \(name) = \(all[name]?.description ?? "?")") }
        }
        if listen > 0 {
            print("listening \(Int(listen))s…")
            try? await Task.sleep(for: .seconds(listen))
        }
        await backend.disconnect()
        exit(0)
    }

    static func client(of backend: VeniceCameraBackend) -> SavonaClient? {
        Mirror(reflecting: backend).children.first { $0.label == "client" }?.value as? SavonaClient
    }

    @MainActor final class Latest {
        var state: CameraState
        init(_ state: CameraState) { self.state = state }
    }

    /// `--send` as a tile sends it: lut=NAME, look=on, desqueeze=1.6x, falsecolor=on (falsecolor:Monitor=on for one
    /// output), framelines=off (framelines:Monitor=on), bars=on, iso=1600, base=3200, flip=on, duration=on.
    static func command(_ line: String) -> CameraCommand? {
        let bits = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard bits.count == 2 else { return nil }
        let on = ["on", "true", "1"].contains(bits[1].lowercased())
        let key = bits[0].split(separator: ":", maxSplits: 1).map(String.init)
        switch key[0] {
        case "lut": return .setLUT(bits[1])
        case "look": return .setLook(on)
        case "desqueeze": return .setDesqueeze(bits[1])
        case "falsecolor": return key.count > 1 ? .setMonitorOverlay(.falseColor, on, output: key[1]) : .setFalseColor(on)
        case "framelines": return key.count > 1 ? .setMonitorOverlay(.frameGuides, on, output: key[1])
            : .setMonitorOverlay(.frameGuides, on, output: nil)
        case "bars": return .setColorBars(on)
        case "iso": return Int(bits[1]).map { .setISO($0) }
        case "base": return Int(bits[1]).map { .setBaseISO($0) }
        case "flip": return .setImageFlip(on)
        case "duration": return .setTimecodeShowsDuration(on)
        default: return nil
        }
    }

    static func mp(_ obj: Any) -> MPValue? {
        switch obj {
        case let s as String: return .string(s)
        case let i as Int: return .int(Int64(i))
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        case let a as [Any]: return .array(a.compactMap(mp))
        case let m as [String: Any]:
            var out: [String: MPValue] = [:]
            for (k, v) in m { if let value = mp(v) { out[k] = value } }
            return .map(out)
        default: return nil
        }
    }
}

