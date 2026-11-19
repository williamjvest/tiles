import CameraCore
import Foundation
import os

/// A Sony VENICE / VENICE 2 over its Web Remote's protocol (Sony's Savona API: MessagePack-RPC over a WebSocket at
/// `/linear`). Built from the open-source clients (ckohen/savona and its dlid predecessor), a DIT's captured VENICE
/// frames and the VENICE page's own value table (docs/venice.md), before the first session with a camera; every name
/// that varies between bodies is a list of candidates, and whichever the camera has is the one used (resolved from
/// `System.GetProperties`, with a substring fallback for names the list missed). What the camera didn't answer stays
/// nil, so its tile is gray rather than wrong.
///
/// Commands go one at a time and nothing is pipelined (a VENICE can crash reconnecting on a poor link); REC is a key
/// press, the shape in the captured frames, never optimistic, and absolute — `record(true)` is only sent to a camera
/// that says it isn't recording. The page's keep-alive (`Network.Connection.KeepAlive`) is read when the camera has
/// been quiet, which doubles as the link check: two silent keep-alives in a row drop the connection and the controller
/// reconnects on its own backoff.
///
/// Latency is the round trip of the last few requests. Everything unusual is logged (`com.toldwell.twcc`, category
/// `venice`) — `log stream --predicate 'subsystem == "com.toldwell.twcc"'` on a Mac watching one.
public actor VeniceCameraBackend: CameraBackend {
    public nonisolated let updates: AsyncStream<CameraState>
    nonisolated let continuation: AsyncStream<CameraState>.Continuation

    let client: SavonaClient
    let host: String
    private let label: String
    let log = Logger(subsystem: "com.toldwell.twcc", category: "venice")

    /// The candidate property names per field, VENICE 1 and VENICE 2 and the PXW family's shared ones. First the
    /// camera has wins.
    private struct Names {
        static let model = ["System.ModelName"]
        // VENICE 2: Storage.Media.Recording {"media.5": "Recording", the others "NotRecording"}.
        static let recorder = ["Storage.Media.Recording", "P.Clip.Mediabox.Status", "Clip.Recorder",
                               "Camcorder.Status.Recorder"]
        static let timecode = ["P.Clip.Mediabox.TimeCode.Value", "Clip.Mediabox.TimeCode.Value"]
        static let clipName = ["Clip.Mediabox.ClipName", "P.Clip.Mediabox.ClipName"]
        static let ei = ["Camera.Gain.ExposureIndex.Value", "Camera.Gain.Value"]
        static let baseISO = ["Camera.Gain.ISOValue", "Camera.Gain.BaseISO"]
        static let shutterMode = ["Camera.Shutter.Mode", "Camera.Shutter.SelectMode"]
        static let shutterAngle = ["Camera.Shutter.Angle.DisplayValue", "Camera.Shutter.Angle", "Camera.Shutter.Angle.Value",
                                   "Camera.Shutter.Value.DisplayValue"]
        static let shutterSpeed = ["Camera.Shutter.Speed.DisplayValue", "Camera.Shutter.Speed"]
        static let nd = ["Camera.NDFilter.Value", "Camera.ND.Filter.Value"]
        static let ndMode = ["Camera.NDFilter.Mode", "Camera.NDFilter.SettingMethod"]
        static let kelvin = ["Camera.WhiteBalance.ColorTemperature.Value", "Camera.WhiteBalance.ColorTemperature.Value.Venice"]
        static let tint = ["Camera.WhiteBalance.ColorTemperature.Tint.Value", "Camera.WhiteBalance.Tint.Value",
                           "Camera.WhiteBalance.Tint"]
        static let awb = ["Camera.WhiteBalance.AutoWhite", "P.Control.AutoWhiteBalance"]
        static let sqEnabled = ["Camera.SlowAndQuickMotion.Enabled"]
        static let sqRate = ["Camera.SlowAndQuickMotion.FrameRate", "Camera.SlowAndQuickMotion.FrameRate.Venice"]
        static let fps = ["P.Clip.Mediabox.Video.Format.FrameRate", "Camera.ProjectFrameRate.Value", "Video.Format.FrameRate",
                          "System.Frequency"]  // VENICE 2: P.Clip.Mediabox.Video.Format.FrameRate "23.98"
        static let imager = ["System.Menu.CamImagermode", "P.System.Menu.CamImagermode"]
        static let irisF = ["Camera.Iris.Value", "Camera.Iris.FValueFraction", "Camera.Iris.FValue"]
        static let irisAuto = ["Camera.Iris.SettingMethod"]  // Automatic / Manual
        static let battery = ["System.Battery.Active.Remain.Percentage"]
        static let mediaTime = ["Storage.Media.AvailableTime", "P.System.Menu.WebInfo.Media.AXSA"]
        static let cameraID = ["System.CameraID"]
        static let colorBars = ["System.Menu.ColorBar", "Camera.ColorBar.Enabled"]
        static let keepAlive = [SavonaClient.keepAliveProperty]
        // The template's further tiles (LayoutTemplates.veniceCells). VENICE 1's page names; VENICE 2's come from its
        // dump, and the fuzzy fallback catches a renamed one.
        static let codec = ["System.Menu.AxsRecformatSelect", "System.Menu.RecFormat", "System.Menu.RecordingFormat", "System.Menu.FormatCodec",
                            "System.Menu.SxsRecformat"]
        static let desqueeze = ["System.Menu.SxsOutputDeSqueeze", "System.Menu.OutputDeSqueeze", "System.Menu.DeSqueeze"]
        static let markerSdi = ["System.Menu.MarkerSdi12Onoff", "System.Menu.MarkerSdiOnoff"]
        static let markerMonitor = ["System.Menu.MarkerMonitorOnoff"]
        static let markerVf = ["System.Menu.MarkerVfOnoff"]
        static let osdMonitor = ["System.Menu.MonitorOsdDisplayInfoOnoff"]
        // VENICE 1's page names, exact only: VENICE 2 has a P.System.Menu.FalseColor that isn't the switch (its false
        // color is the Monitor and VF Exposure Assist functions on the assignable buttons, `falseColorFunctions`).
        static let falseColor = ["System.Menu.FalseColor", "System.Menu.MonitorFalseColorOnoff",
                                 "Output.Monitor.FalseColor.Enabled"]
        static let clipPosition = ["Clip.Mediabox.AllClipPosition", "P.Clip.Mediabox.AllClipPosition"]
        static let clipTotal = ["Clip.Mediabox.AllTotalClips", "P.Clip.Mediabox.AllTotalClips"]
        static let assign = ["Button.Assign"]
        // The LUT on each output: "Log" is off; "Look", "s709", "R709(800%)" are a LUT (VENICE 1's page:
        // Output.Video.SDI.LUT.Value "Log", Output.Video.ViewFinder.LUT.Value "s709").
        static let lutSdi12 = ["Output.Video.SDI.LUT.Value", "Output.Video.SDI12.LUT.Value", "Output.Video.SDI1.LUT.Value"]
        static let lutSdi34 = ["Output.Video.SDI34.LUT.Value", "Output.Video.SDI3.LUT.Value"]
        static let lutMonitor = ["Output.Video.Monitor.LUT.Value", "Output.Video.MONITOR.LUT.Value", "New.LUT.Monitor"]
        static let lutVf = ["Output.Video.ViewFinder.LUT.Value", "Output.Video.VF.LUT.Value"]
        static let markerSdi34 = ["System.Menu.MarkerSdi34Onoff", "System.Menu.MarkerSdi3Onoff"]
        static let vfFalseColor = ["System.Menu.VfFalseColor", "System.Menu.FalseColorVfOnoff", "System.Menu.VfFalseColorOnoff"]
        // The info overlay on each output and HDMI's frame lines (VENICE 2 manual p. 89–90). VENICE 1's page has
        // SdiOsd… / VfOsd… / MonitorOsd…DisplayInfoOnoff; the SDI 3/4 and HDMI names are guesses in that style.
        static let osdSdi12 = ["System.Menu.SdiOsdDisplayInfoOnoff", "System.Menu.Sdi12OsdDisplayInfoOnoff"]
        // VENICE 2 has one SDI overlay switch for SDI 1/2 and 3/4 (its menu's "SDI Overlay" under both): the same
        // property, so the two outputs show it together, as the camera does.
        static let osdSdi34 = ["System.Menu.SdiOsdDisplayInfoOnoff", "System.Menu.Sdi34OsdDisplayInfoOnoff",
                               "System.Menu.Sdi3OsdDisplayInfoOnoff"]
        static let osdVf = ["System.Menu.VfOsdDisplayInfoOnoff"]
        static let osdHdmi = ["System.Menu.HdmiOsdDisplayInfoOnoff"]
        static let markerHdmi = ["System.Menu.MarkerHdmiOnoff"]
        // The viewfinder's zebra (VF Function > Zebra): VENICE 1's page calls it EvfZebraOnoff.
        static let zebraVf = ["System.Menu.EvfZebraOnoff", "System.Menu.VfZebraOnoff"]
        // Peaking, one switch for the viewfinder and the Monitor out (VENICE 2's menu: "0"/"1", WebMenu.js L3_SETTING_PEAKING).
        static let peaking = ["System.Menu.PeakingOnoff"]

        static let all: [[String]] = [model, recorder, timecode, clipName, ei, baseISO, shutterMode, shutterAngle,
                                      shutterSpeed, nd, ndMode, kelvin, tint, awb, sqEnabled, sqRate, fps, imager,
                                      irisF, battery, mediaTime, cameraID, colorBars, keepAlive, codec, desqueeze,
                                      markerSdi, markerMonitor, markerVf, osdMonitor, falseColor, clipPosition,
                                      clipTotal, assign, lutSdi12, lutSdi34, lutMonitor, lutVf, markerSdi34,
                                      vfFalseColor, osdSdi12, osdSdi34, osdVf, osdHdmi, markerHdmi, zebraVf, peaking]
    }

    /// What VENICE 2 reads alongside the fields (its look, the outputs' links and locks, the menu's de-squeeze and
    /// color bars), asked once on connect and then followed by notification.
    static let extraProperties = [
        "Camera.NDFilter.Enabled", "Camera.WhiteBalance.ColorTemperature.Type", flipImage, mediaboxStatus, mediaboxSpeed,
        VeniceMenu.shutterModeProperty, VeniceMenu.projectRateProperty, batteryVolts, clipCameraID, clipReel, clipPosition,
        timeDataDisplay, VeniceMenu.desqueezeProperty, VeniceMenu.desqueezeVisible, VeniceMenu.colorBarProperty,
        colorBarEnabled, lookMode, lookPreset, lookUserFileID, lookUserFileName, lookARTFileID, lookARTFileName,
        "Output.Video.SDI.LUT.Value.LockStatus", "Output.Video.ViewFinder.LUT.Value.LockStatus",
        VeniceMenu.followsSdi34, VeniceMenu.followsMonitor, VeniceMenu.followsHdmi, VeniceMenu.monitorOutSource,
    ]
    /// The option lists Tiles reads besides the fields' own.
    static let extraLists = [
        "Camera.WhiteBalance.ColorTemperature.Value", "Camera.WhiteBalance.ColorTemperature.Tint.Value",
        "Camera.WhiteBalance.ColorTemperature.Type", VeniceMenu.imagerModeAllowed, VeniceMenu.recordingFormatAllowed,
        VeniceMenu.projectRateAllowed, VeniceMenu.desqueezeAllowed, lookMode, lookPreset, userLUTList, artList,
    ]

    /// The property each field actually uses, resolved once the camera has listed its names.
    var property: [Field: String] = [:]
    enum Field: String, CaseIterable {
        case model, recorder, timecode, clipName, ei, baseISO, shutterMode, shutterAngle, shutterSpeed, nd, ndMode,
             kelvin, tint, awb, sqEnabled, sqRate, fps, imager, irisF, battery, mediaTime, cameraID, colorBars,
             keepAlive, codec, desqueeze, markerSdi, markerMonitor, markerVf, osdMonitor, falseColor, clipPosition,
             clipTotal, assign, lutSdi12, lutSdi34, lutMonitor, lutVf, markerSdi34, vfFalseColor, osdSdi12, osdSdi34, osdVf,
             osdHdmi, markerHdmi, zebraVf, lutHdmi, peaking

        /// Fields no word match may stand in for: a near name there is something else.
        var exactOnly: Bool { self == .falseColor || self == .vfFalseColor || self == .lutHdmi }

        var candidates: [String] {
            switch self {
            case .model: Names.model
            case .recorder: Names.recorder
            case .timecode: Names.timecode
            case .clipName: Names.clipName
            case .ei: Names.ei
            case .baseISO: Names.baseISO
            case .shutterMode: Names.shutterMode
            case .shutterAngle: Names.shutterAngle
            case .shutterSpeed: Names.shutterSpeed
            case .nd: Names.nd
            case .ndMode: Names.ndMode
            case .kelvin: Names.kelvin
            case .tint: Names.tint
            case .awb: Names.awb
            case .sqEnabled: Names.sqEnabled
            case .sqRate: Names.sqRate
            case .fps: Names.fps
            case .imager: Names.imager
            case .irisF: Names.irisF
            case .battery: Names.battery
            case .mediaTime: Names.mediaTime
            case .cameraID: Names.cameraID
            case .colorBars: Names.colorBars
            case .keepAlive: Names.keepAlive
            case .codec: Names.codec
            case .desqueeze: Names.desqueeze
            case .markerSdi: Names.markerSdi
            case .markerMonitor: Names.markerMonitor
            case .markerVf: Names.markerVf
            case .osdMonitor: Names.osdMonitor
            case .falseColor: Names.falseColor
            case .clipPosition: Names.clipPosition
            case .clipTotal: Names.clipTotal
            case .assign: Names.assign
            case .lutSdi12: Names.lutSdi12
            case .lutSdi34: Names.lutSdi34
            case .lutMonitor: Names.lutMonitor
            case .lutVf: Names.lutVf
            case .markerSdi34: Names.markerSdi34
            case .vfFalseColor: Names.vfFalseColor
            case .osdSdi12: Names.osdSdi12
            case .osdSdi34: Names.osdSdi34
            case .osdVf: Names.osdVf
            case .osdHdmi: Names.osdHdmi
            case .markerHdmi: Names.markerHdmi
            case .zebraVf: Names.zebraVf
            case .lutHdmi: []  // VENICE 2's "hdmi" entry in the viewfinder LUT map, set on connect
            case .peaking: Names.peaking
            }
        }
    }

    /// Last value per property, by the camera's own name. `pending` holds a value Tiles asked for until the camera
    /// confirms it (or three seconds pass and the camera's value returns).
    var values: [String: MPValue] = [:]
    var options: [String: [MPValue]] = [:]
    /// Whether each property (or menu item, `….MenuItem`) can be changed now: "Locked" / "Unlocked"
    /// (`Property.GetStatus`, then `Notify.Property.Status.Changed`). A locked one's tile is grayed.
    var statuses: [String: String] = [:]
    /// The LUT each output last showed, so turning it back on restores that one rather than a default.
    var lastLUT: [String: String] = [:]
    var pending: [String: MPValue] = [:]
    var pendingSince: [String: Date] = [:]
    /// An assignable button pressed for its function (false color, color bars), by slot: the state asked for, until
    /// `Button.Assign` reports it.
    var pendingKeys: [String: (on: Bool, since: Date)] = [:]
    /// Outputs showing another output's overlays now (`MonitorOutput.follows`), left out of writes to every output.
    var followers: Set<String> = []
    /// The last timecode the camera reported (its text, as frames, and when), whether it's advancing, and the highest
    /// frame number seen (which says how a high frame rate is counted).
    var timecodeSeen: (text: String, frames: Int, at: Date)?
    var timecodeAdvancing = false
    var timecodeHighestFrame = 0
    var state = CameraState()
    var listening: Task<Void, Never>?
    var keepAliveTask: Task<Void, Never>?
    var relistTask: Task<Void, Never>?
    var recConfirmTimeout: TimeInterval = 6
    var recentLatencies: [Double] = []
    var quietKeepAlives = 0
    /// A Camera Menu key is out (one at a time: a key the camera doesn't answer holds every request behind it for its
    /// 3 s); and the keys this camera didn't answer, or turned down, which aren't offered again on this connection.
    var menuKeyInFlight = false
    var unansweredKeys: Set<String> = []
    /// A pick from the Clips window is being stepped to (`goToClip`), and the clip it's heading for now: a newer pick
    /// changes it.
    var steppingToClip = false
    var clipTarget: Int?

    public init(host: String, user: String? = "admin", password: String?, label: String = "V") {
        self.host = host
        self.label = label
        client = SavonaClient(host: host, user: user, password: password) { category, message in
            Logger(subsystem: "com.toldwell.twcc", category: category).notice("\(message, privacy: .public)")
        }
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(4))
        updates = stream.stream
        continuation = stream.continuation
        state.make = .sony
        state.model = "VENICE"
    }

    /// The last state handed out (`yield`): only a changed one goes out.
    var lastYielded: CameraState?

    // MARK: - CameraBackend

    public func connect() async {
        guard state.connection != .connected && state.connection != .connecting else { return }
        state.connection = .connecting
        unansweredKeys = []
        menuKeyInFlight = false
        yield()
        do {
            // A VENICE refuses a new client for a few seconds after the last one let go (VENICE 2: every quit and
            // reopen failed once). Two quiet retries, 3 s apart, before calling it failed; never faster.
            var attempt = 0
            while true {
                do {
                    try await client.connect()
                    break
                } catch where attempt < 2 && Self.isRefused(error) {
                    attempt += 1
                    await client.close()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            try await loginFollowUp()
        } catch {
            log.error("connect failed: \(String(describing: error).prefix(200), privacy: .public)")
            ActivityLog.shared.note(host, "VENICE connect failed: \(String(describing: error).prefix(140))")
            state.connection = .failed(readableReason(error))
            yield()
            await client.close()
            return
        }
        state.connection = .connected
        ActivityLog.shared.note(host, "VENICE connected (\(state.model ?? "?"))")
        yield()
        listenForChanges()
        scheduleKeepAlive()
        Task { await self.readUserFramesAndMeters() }
    }

    /// Reads made once connected, so they can't hold the connection up: the user frame line switches, then the
    /// meters and S&Q's 1× flag, then each output's frame line set and info set with the sets' audio meters, in
    /// requests of their own and with the page's 3 s, so a camera that doesn't know one costs the others nothing. Unanswered is logged, not left looking like "not on this camera". The camera notifies
    /// changes to all of them after this (the meters several times a second), read or not.
    private func readUserFramesAndMeters() async {
        let userFrames = [Self.userFrameA.first, Self.userFrameA.second, Self.userFrameB.first, Self.userFrameB.second]
        for names in [userFrames, [Self.audioMeters, Self.slowAndQuickAtOneTimes], Self.outputOptionNames] {
            guard state.connection == .connected else { return }
            do {
                let answered = try await client.get(names, timeout: 3)
                values.merge(answered) { _, new in new }
            } catch {
                let list = names.joined(separator: ", ")
                log.notice("not read: \(list, privacy: .public): \(String(describing: error).prefix(100), privacy: .public)")
                ActivityLog.shared.note(host, "VENICE didn't answer \(list): \(String(describing: error).prefix(80))")
            }
        }
        rebuild()
        yield()
    }

    /// After login: model, property names, what the camera's values are right now.
    private func loginFollowUp() async throws {
        var names = Set((try? await client.propertyNames()) ?? [])
        if names.isEmpty {
            // VENICE 2 (savona-2.9.4) doesn't answer System.GetProperties: read every candidate, and its "P." twin
            // (the menu's names are P.System.Menu.… there), and keep the names that answer.
            var asked = Set<String>()
            for field in Field.allCases {
                for name in field.candidates {
                    asked.insert(name)
                    if name.hasPrefix("System.Menu.") { asked.insert("P." + name) }
                }
            }
            for chunk in Array(asked).sorted().chunked(into: 60) {
                let answered = (try? await client.get(chunk, timeout: 15)) ?? [:]
                names.formUnion(answered.keys)
                values.merge(answered) { _, new in new }
            }
            log.notice("no property list from the camera; \(names.count, privacy: .public) candidate names answered")
        }
        for field in Field.allCases {
            if let exact = field.candidates.first(where: { names.contains($0) }) {
                property[field] = exact
                continue
            }
            if field.exactOnly { continue }
            // A name the list missed: match on the distinctive words (e.g. anything with "NDFilter" and "Value").
            let words = field.candidates.map { $0.split(separator: ".").dropFirst().map(String.init) }
            if let candidate = names.sorted().first(where: { name in
                let bits = Set(name.split(separator: ".").map(String.init))
                return words.contains { $0.allSatisfy { bits.contains($0) } }
            }) {
                property[field] = candidate
                let message = "\(field.rawValue) → fuzzy match \(candidate)"
                log.notice("\(message, privacy: .public)")
            } else {
                let message = "\(field.rawValue): no property on this camera"
                log.notice("\(message, privacy: .public)")
            }
        }
        // VENICE 2: the LUTs live in two maps, one entry per output.
        if values["Output.Video.SDI.LUT.Value"]?.map != nil {
            property[.lutSdi12] = "Output.Video.SDI.LUT.Value#sdi1"
            property[.lutSdi34] = "Output.Video.SDI.LUT.Value#sdi3"
        }
        if let outputs = values["Output.Video.ViewFinder.LUT.Value"]?.map {
            property[.lutMonitor] = "Output.Video.ViewFinder.LUT.Value#monitor"
            property[.lutVf] = "Output.Video.ViewFinder.LUT.Value#vf"
            if outputs["hdmi"] != nil { property[.lutHdmi] = "Output.Video.ViewFinder.LUT.Value#hdmi" }
        }
        let resolved = property.count
        let total = Field.allCases.count
        log.notice("resolved \(resolved, privacy: .public) of \(total, privacy: .public) fields; camera has \(names.count, privacy: .public) properties")

        let wanted = Array(Set(property.values.map { Self.slot($0)?.base ?? $0 }))
        if !wanted.isEmpty {
            for chunk in wanted.sorted().chunked(into: 20) {
                let answered = (try? await client.get(chunk, timeout: 15)) ?? [:]
                values.merge(answered) { _, new in new }
            }
        }
        if let modelProperty = property[.model], let model = values[modelProperty]?.string,
           model.uppercased().contains("VENICE") || model.uppercased().contains("MPC-") {
            state.model = model  // VENICE 2 says "PXW-X180": keep "VENICE" then
        }
        // Linked properties the page writes alongside the ones Tiles shows (ND's switch, white balance's type), and
        // VENICE 2's look, output links and menu items.
        for chunk in Self.extraProperties.chunked(into: 20) {
            if let extra = try? await client.get(chunk, timeout: 8) { values.merge(extra) { _, new in new } }
        }
        // VENICE 2's menu de-squeeze, in place of VENICE 1's names.
        if values[VeniceMenu.desqueezeProperty] != nil { property[.desqueeze] = VeniceMenu.desqueezeProperty }
        await loadOptions()
        await loadStatuses()
        rebuild()
    }

    /// The locks on what Tiles writes: the properties themselves and the menu items behind them.
    private func loadStatuses() async {
        var names = Set(property.values.map { Self.slot($0)?.base ?? $0 })
        names.formUnion(VeniceMenu.menuLocks.values)
        names.formUnion([Self.colorBarEnabled, Self.userLUTLoad, Self.lutLock, Self.flipImage + ".MenuItem"])
        names.remove(SavonaClient.keepAliveProperty)
        for chunk in names.sorted().chunked(into: 60) {
            if let answered = try? await client.statuses(chunk, timeout: 8) { statuses.merge(answered) { _, new in new } }
        }
    }

    func loadOptions() async {
        // The camera's white balance steps (VENICE 2: 17, set up on the body), the menu lists (the item indices allowed
        // now, VeniceMenu) and the look's lists (its modes, presets, the user 3D LUTs and ART files loaded).
        for name in Self.extraLists {
            let list = await client.options(for: name)
            if !list.isEmpty { options[name] = list }
        }
        // The lists Tiles offers: EI, ND, shutter angle, shutter speed, frame rate. Whatever the camera answers.
        for (field, asLabels) in [(Field.ei, true), (Field.nd, true), (Field.shutterAngle, true),
                                  (Field.shutterSpeed, false), (Field.sqRate, true), (Field.fps, false),
                                  (Field.imager, true), (Field.codec, true), (Field.desqueeze, true),
                                  (Field.lutMonitor, true), (Field.lutVf, true), (Field.lutHdmi, true)] {
            guard let name = property[field] else { continue }
            // A LUT slot's list is its own capability; the speed list is Camera.Shutter.Speed's (values "1/24.00").
            let capability = field == .shutterSpeed && name.hasSuffix("Speed.DisplayValue") ? "Camera.Shutter.Speed"
                : Self.capabilityName(name)
            options[name] = await client.options(for: capability)
            if asLabels, let list = options[name], !list.isEmpty {
                let text = list.prefix(40).map(\.description).joined(separator: ", ")
                log.notice("\(name, privacy: .public) options: \(text.prefix(300), privacy: .public)")
            }
        }
    }

    public func disconnect() async {
        listening?.cancel()
        keepAliveTask?.cancel()
        relistTask?.cancel()
        await client.close()
        state.connection = .disconnected
        yield()
    }

    public func send(_ command: CameraCommand) async {
        guard state.connection == .connected else { return }
        if let reason = refusal(command) {
            log.notice("not sent, \(reason, privacy: .public): \(String(describing: command).prefix(80), privacy: .public)")
            // In the Activity Log too, so a report from set (Settings → Copy Activity Log) says what was held back and why.
            ActivityLog.shared.note(host, "VENICE not sent, \(reason): \(String(describing: command).prefix(80))")
            return
        }
        switch command {
        case .record(let start):
            await record(start)
        case .setISO(let value):
            // In the camera's own shape: "1600EI" where it reads "800EI" (shapeValue), as the page's SET_EI sends it.
            // A Double went through a format here and sent "1600.0EI" (found against the mock).
            if let name = property[.ei] { await write(.int(Int64(value)), for: name) }
        case .setBaseISO(let value):
            // Camera.Gain.ISOValue is 0 (Normal base) / 1 (High base); the tile speaks the ISO numbers.
            if let name = property[.baseISO] {
                let high = value >= Self.baseISOPair(model: state.model, reading: values[name]).1
                if values[name]?.string?.uppercased().hasPrefix("ISO") == true {
                    await write(.string("ISO \(value)"), for: name)  // VENICE 2: "ISO 800" / "ISO 3200"
                } else {
                    await write(MPValue(high ? 1 : 0), for: name)
                }
                await moveEIToBase(value, high: high, baseProperty: name)
            }
        case .setShutterAngle(let angle):
            if let name = property[.shutterAngle] {
                if name.hasSuffix("DisplayValue"), let mode = property[.shutterMode] {
                    // VENICE 2's page sends the mode with the value (rm.html, savona-2.9.4).
                    await writeAll([mode: .string("Angle"), name: .string(Self.angleString(angle))])
                } else {
                    await write(.double(angle), for: name, format: { .string(Self.angleString($0)) })
                }
            }
        case .setShutterSpeed(let speed):
            if let name = property[.shutterSpeed] {
                if name.hasSuffix("DisplayValue"), let mode = property[.shutterMode] {
                    await writeAll([mode: .string("Speed"), name: .string(Self.speedValue(speed))])
                } else {
                    await write(.string(speed), for: name)
                }
            }
        case .setShutterMode(let mode) where values[VeniceMenu.shutterModeProperty] != nil:
            // VENICE 2: Technical > Shutter Mode, "1" Angle / "0" Speed (WebMenu.js); Camera.Shutter.Mode only reads.
            await write(.string(mode == .angle ? "1" : "0"), for: VeniceMenu.shutterModeProperty)
        case .setShutterMode(let mode):
            if let name = property[.shutterMode] {
                // VENICE 2 changes mode together with a value: the one the other mode shows now.
                let other = mode == .angle ? property[.shutterAngle] : property[.shutterSpeed]
                if let other, other.hasSuffix("DisplayValue"), let shown = values[other]?.unwrapped.string {
                    await writeAll([name: .string(mode == .angle ? "Angle" : "Speed"), other: .string(shown)])
                } else {
                    await write(.string(mode == .angle ? "Angle" : "Speed"), for: name)
                }
            }
        case .setNDPreset(let label):
            if let name = property[.nd] {
                let enabled = "Camera.NDFilter.Enabled"
                if label == "Clear", let modeName = property[.ndMode] {
                    // VENICE 2's page: Mode "PresetClear" with Value 1 (NDConverter.js, savona-2.9.4).
                    await writeAll([modeName: .string("PresetClear"), name: .int(1)])
                } else if let value = Self.ndValue(for: label) {
                    if let modeName = property[.ndMode] {
                        var props: [String: MPValue] = [modeName: .string("Preset"), name: .int(Int64(value))]
                        if values[enabled]?.unwrapped.bool == false { props[enabled] = .bool(true) }
                        await writeAll(props)
                    } else {
                        await write(MPValue(value), for: name)
                    }
                }
            }
        case .setKelvin(let kelvin):
            await writeWhiteBalance(kelvin: Int(kelvin), tint: nil)
        case .setTint(let tint):
            await writeWhiteBalance(kelvin: nil, tint: Int(tint))
        case .setWhiteBalancePreset(let preset):
            // VENICE 2's own steps (up to 16, edited on the camera): Kelvin, tint and type together, as the page does.
            if let step = wbSteps.first(where: { $0.label == preset }), let kName = property[.kelvin], let tName = property[.tint] {
                await writeAll([kName: .string(String(step.kelvin)), tName: .string(String(step.tint)),
                                "Camera.WhiteBalance.ColorTemperature.Type": .string(step.type)])
            } else if preset.hasSuffix("K"), let kelvin = Double(preset.dropLast()) {
                await writeWhiteBalance(kelvin: Int(kelvin), tint: 0)
            }
        case .setIris(let f):
            if let name = property[.irisF] { await write(.double(f), for: name) }
        case .setImageFlip(let on):
            // VENICE 2: Monitoring > Output Display > Flip Image, "3" H&V / "0" Off — what the camera's own
            // HAndVFlip assignable button sets (VENICE 2). Otherwise the slot that carries a flip.
            if values[Self.flipImage] != nil {
                await write(.string(on ? "3" : "0"), for: Self.flipImage)
            } else if let slot = assignedSlot(matching: ["flip", "inversion", "invert"]) {
                await sendKey(slot)
            }
        case .setColorBars(let on):
            // VENICE 2: the menu's own switch while its item is unlocked; otherwise the camera's property, or a button
            // the bars are assigned to. One of them, never two (each ignored write holds the queue for 3 s).
            if values[VeniceMenu.colorBarProperty] != nil, statuses[VeniceMenu.colorBarLock] != "Locked" {
                await write(.string(on ? "1" : "0"), for: VeniceMenu.colorBarProperty)
            } else if let name = property[.colorBars], statuses[name] != "Locked" {
                await write(.bool(on), for: name)
            } else {
                await pressAssigned("ColorBar", toBe: on)
            }
        case .setFrameRate(let fps):
            if values[VeniceMenu.projectRateProperty] != nil, let value = VeniceMenu.value(VeniceMenu.projectRates, label: fps) {
                await write(.string(value), for: VeniceMenu.projectRateProperty)  // VENICE 2: the menu's own setting
            } else if let name = property[.fps] {
                await write(.string(fps), for: name)
            }
        case .setFrameRateVariable(let on):
            if let name = property[.sqEnabled] {
                if let rateName = property[.sqRate], let rate = values[rateName]?.unwrapped.number {
                    // VENICE 2's page sends the switch with its rate and denominator (rm.html, savona-2.9.4).
                    var props = Self.sqRateProps(rateName, rate)
                    props[name] = .bool(on)
                    await writeAll(props)
                } else {
                    await write(.bool(on), for: name)
                }
            }
        case .setFrameRateVariableRate(let rate):
            if let name = property[.sqRate] {
                if let enabled = property[.sqEnabled] {
                    var props = Self.sqRateProps(name, rate)
                    props[enabled] = .bool(true)
                    await writeAll(props)
                } else {
                    await write(.double(rate), for: name)
                }
            }
        case .setClipCameraID(let letter):
            if values[Self.clipCameraID] != nil, let code = letter.unicodeScalars.first?.value {
                await write(.string(String(code)), for: Self.clipCameraID)  // VENICE 2: the letter's ASCII code, "66" = B
            } else if let name = property[.cameraID] {
                await write(.string(letter), for: name)
            }
        case .setClipReel(let reel):
            if values[Self.clipReel] != nil { await write(.string(String(reel)), for: Self.clipReel) }
        case .setClipCameraPosition(let position):
            if let index = ["C", "L", "R"].firstIndex(of: position) {
                await write(.string(String(index)), for: Self.clipPosition)
            }
        case .setTimecodeShowsDuration(let duration):
            await write(.string(duration ? "2" : "3"), for: Self.timeDataDisplay)
        case .setResolution(let mode):
            if let name = property[.imager] {
                let menuValue = name.hasSuffix("System.Menu.CamImagermode") ? VeniceMenu.value(VeniceMenu.imagerModes, label: mode) : nil
                await write(.string(menuValue ?? mode), for: name)
            }
        case .setFileFormat(let codec):
            if let name = property[.codec] {
                let menuValue = name.hasSuffix("System.Menu.AxsRecformatSelect")
                    ? VeniceMenu.value(VeniceMenu.recordingFormats, label: codec) : nil
                await write(.string(menuValue ?? codec), for: name)
            }
        case .setDesqueeze(let ratio):
            if property[.desqueeze] == VeniceMenu.desqueezeProperty {
                // VENICE 2's menu value for the ratio (1.6x is "6").
                if let value = VeniceMenu.value(VeniceMenu.desqueeze, label: ratio) {
                    await write(.string(value), for: VeniceMenu.desqueezeProperty)
                }
            } else if let name = property[.desqueeze] {
                // A camera that reads the ratio as an index takes it back as one.
                let current = values[name]?.string ?? values[name]?.unwrapped.string ?? ""
                if Int(current) != nil, let index = VeniceDesqueeze.all.firstIndex(of: ratio) {
                    await write(.string(String(index)), for: name)
                } else {
                    await write(.string(ratio), for: name)
                }
            }
        case .setFalseColor(let on):
            await setFalseColor(on, output: nil)
        case .setMonitorOverlay(.falseColor, let on, let output):
            await setFalseColor(on, output: output)
        case .setLUT(let name):
            await setLUT(name)
        case .setLook(let on):
            for name in overlayProperties(.lut, output: nil) { await write(lutValue(on, for: name), for: name) }
        case .setMonitorOverlay(.lut, let on, let output):
            for name in overlayProperties(.lut, output: output) { await write(lutValue(on, for: name), for: name) }
        case .setMonitorOverlay(.audioMeters, let on, let output):
            // The info set that output shows (every output's, with nil): its audio level meter.
            let ids = output.map { [$0] } ?? Array(Self.infoSetSelect.keys)
            let meters = Set(ids.compactMap { Self.infoSetSelect[$0] }
                .compactMap { (livePending($0) ?? values[$0])?.unwrapped.string }
                .compactMap { Self.audioMeterInInfoSet[$0] })
            for name in meters.sorted() { await write(.string(on ? "1" : "0"), for: name) }
        case .setFrameLineSet(let set, let output):
            if let name = Self.frameLineSelect[output] { await write(.string(set == .b ? "1" : "0"), for: name) }
        case .setMonitorOverlay(let overlay, let on, let output):
            for name in overlayProperties(overlay, output: output) { await write(.bool(on), for: name) }
        case .playback(let command):
            await play(command)
        case .pressCameraButton(let button):
            await pressMenuKey(button)
        case .setUserFrameLines(let set, let label):
            await setUserFrameLines(set, label)
        default:
            break  // nothing on a VENICE for the rest (variable ND, clip flags, Sony's HDMI info and grid lines…)
        }
        yield()
    }
}
