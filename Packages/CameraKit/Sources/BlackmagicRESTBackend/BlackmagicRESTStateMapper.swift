import CameraCore
import Foundation

/// Maps Blackmagic REST API responses to CameraState fields. Shapes as a PYXIS 12K (Camera 10.1) sends them.
///
/// - shutterAngle — the API carries it ×100 (18000 is 180°). /video/shutter holds only the value of the current
///   measurement ("ShutterAngle" or "ShutterSpeed").
/// - frame rate, codec and resolution — from /system/format, with the choices the matching /system/supportedFormats
///   entry allows. The PYXIS has no /system/codecFormat: its codec is the format's ("BRaw:8_1").
/// - iris — nil while /lens/iris/description says the lens isn't controllable.
/// - monitoring — /monitoring/{output}/{overlay} output by output (the backend assembles it); look and falseColor are
///   the display LUT and false color on every output.
/// - dynamicRange — /system/dynamicRange, the choices from /system/supportedDynamicRanges.
/// - frame rate's variable rate — the format's offSpeedFrameRate, within its min and max.
/// - lut, baseISO, desqueeze, focusMode — nil: the API selects no LUT on its own (presets swap a whole setup), and
///   has no base ISO, de-squeeze or focus mode.
/// - mediaRemainingMinutes — the active disk's remainingRecordTime ÷ 60 (the working set pads with nulls).
/// - fileNaming — the slate: the camera letter, and the reel, which a PYXIS keeps with the card ("Reel number is not
///   editable"). No clipName: the slate calls the next clip only "Next Clip", and a clip's file name
///   ("A001_07171155_C063") also carries the time it starts and its number on the card. No title either.
/// - dynamicRange — accepts a subscription but never pushes: the backend reads it back.
/// - whiteBalance — the preset menu is Tiles' presets on every camera (`WhiteBalancePresets`, in the camera's range)
///   and Auto, which takes the white balance from the middle of the picture once. A preset sets the Kelvin only.
/// - playback — Live | Review, as the FX3's: the transport mode, InputPreview or Output.
/// - nativeISOs — not in the API: Blackmagic's specifications, model by model (`nativeISOs(model:)`).
enum BlackmagicRESTStateMapper {

    // MARK: - Full initial state

    struct InitialPayload {
        var product: ProductResponse?
        var format: FormatResponse?
        var codecFormat: CodecFormatResponse?
        var supportedCodecFormats: SupportedCodecFormatsResponse?
        var supportedFormats: [SupportedFormat] = []
        var iso: ISOResponse?
        var supportedISOs: SupportedISOsResponse?
        var shutter: ShutterResponse?
        var shutterMeasurement: ShutterMeasurementResponse?
        var supportedShutters: SupportedShuttersResponse?
        var whiteBalance: WhiteBalanceResponse?
        var whiteBalanceDescription: WhiteBalanceDescriptionResponse?
        var whiteBalanceTint: WhiteBalanceTintResponse?
        var whiteBalanceTintDescription: WhiteBalanceTintDescriptionResponse?
        var ndFilter: NDFilterResponse?
        var supportedNDFilters: SupportedNDFiltersResponse?
        var iris: IrisResponse?
        var irisDescription: IrisDescriptionResponse?
        var workingset: WorkingSetResponse?
        var power: PowerResponse?
        var record: RecordResponse?
        // Monitoring: first display's state (nil when camera has no displays)
        var displayLUT: MonitoringEnabledResponse?    // GET /monitoring/{name}/displayLUT
        var falseColor: MonitoringEnabledResponse?    // GET /monitoring/{name}/falseColor
        var colorBars: MonitoringEnabledResponse?     // GET /camera/colorBars
        var dynamicRange: DynamicRangeResponse?
        var supportedDynamicRanges: SupportedDynamicRangesResponse?
        // Playback
        var transport: TransportResponse?             // /transports/0
        var playing: Bool?                            // /transports/0/play
        var clipIndex: ClipIndexResponse?             // /transports/0/clipIndex
        var timeline: TimelineResponse?               // /timelines/0
        var slate: SlateResponse?                     // /slates/nextClip

        /// The subscribed properties, from their values in the camera's subscribe answers. A property the camera
        /// refused (it hasn't got it) stays nil, as a read answered 501 would.
        mutating func fill(from values: [String: Any], firstDisplay: String?) {
            func value<T: Decodable>(_ property: String, _ type: T.Type) -> T? {
                values[property].flatMap { BlackmagicRESTStateMapper.decode($0, as: T.self) }
            }
            format = value("/system/format", FormatResponse.self)
            codecFormat = value("/system/codecFormat", CodecFormatResponse.self)
            iso = value("/video/iso", ISOResponse.self)
            supportedISOs = value("/video/supportedISOs", SupportedISOsResponse.self)
            shutter = value("/video/shutter", ShutterResponse.self)
            shutterMeasurement = value("/video/shutter/measurement", ShutterMeasurementResponse.self)
            supportedShutters = value("/video/supportedShutters", SupportedShuttersResponse.self)
            whiteBalance = value("/video/whiteBalance", WhiteBalanceResponse.self)
            whiteBalanceDescription = value("/video/whiteBalance/description", WhiteBalanceDescriptionResponse.self)
            whiteBalanceTint = value("/video/whiteBalanceTint", WhiteBalanceTintResponse.self)
            whiteBalanceTintDescription = value("/video/whiteBalanceTint/description", WhiteBalanceTintDescriptionResponse.self)
            ndFilter = value("/video/ndFilter", NDFilterResponse.self)
            supportedNDFilters = value("/video/supportedNDFilters", SupportedNDFiltersResponse.self)
            iris = value("/lens/iris", IrisResponse.self)
            irisDescription = value("/lens/iris/description", IrisDescriptionResponse.self)
            workingset = value("/media/workingset", WorkingSetResponse.self)
            power = value("/camera/power", PowerResponse.self)
            record = value("/transports/0/record", RecordResponse.self)
            colorBars = value("/camera/colorBars", MonitoringEnabledResponse.self)
            dynamicRange = value("/system/dynamicRange", DynamicRangeResponse.self)
            supportedDynamicRanges = value("/system/supportedDynamicRanges", SupportedDynamicRangesResponse.self)
            transport = value("/transports/0", TransportResponse.self)
            playing = values["/transports/0/play"] as? Bool
            clipIndex = value("/transports/0/clipIndex", ClipIndexResponse.self)
            timeline = value("/timelines/0", TimelineResponse.self)
            slate = value("/slates/nextClip", SlateResponse.self)
            if let display = firstDisplay {
                displayLUT = value("/monitoring/\(display)/displayLUT", MonitoringEnabledResponse.self)
                falseColor = value("/monitoring/\(display)/falseColor", MonitoringEnabledResponse.self)
            }
        }
    }

    static func buildInitialState(from p: InitialPayload) -> CameraState {
        var state = CameraState()
        state.connection = .connected
        state.make = .blackmagic

        // Model name
        if let prod = p.product {
            state.model = prod.productName ?? prod.deviceName
            state.nativeISOs = nativeISOs(model: state.model)
        }

        // Recording
        if let rec = p.record {
            state.recording = RecordingControl(state: rec.recording ? .recording : .idle)
        }

        // Frame rate, codec and resolution
        if let fmt = p.format {
            applyFormat(fmt, supported: p.supportedFormats, to: &state)
        }
        // A camera whose format has no codec names it, with its container, at /system/codecFormat.
        if p.format?.codec == nil, let codec = p.codecFormat {
            let formats = p.supportedCodecFormats?.codecs?.map { codecLabel($0) } ?? []
            state.fileFormat = Choice(codecLabel(codec), options: formats)
        }

        // ISO
        if let iso = p.iso {
            let opts = p.supportedISOs?.supportedISOs ?? [iso.iso]
            state.iso = Choice(iso.iso, options: opts)
        }

        // Shutter
        applyShutter(to: &state, shutter: p.shutter, measurement: p.shutterMeasurement, supported: p.supportedShutters)

        // White balance
        if let wb = p.whiteBalance, let desc = p.whiteBalanceDescription {
            let tintLevel: Level?
            if let tint = p.whiteBalanceTint, let tdesc = p.whiteBalanceTintDescription {
                tintLevel = Level(Double(tint.whiteBalanceTint),
                                  range: Double(tdesc.whiteBalanceTint.min)...Double(tdesc.whiteBalanceTint.max),
                                  step: 1)
            } else {
                tintLevel = nil
            }
            let range = Double(desc.whiteBalance.min)...Double(desc.whiteBalance.max)
            state.whiteBalance = WhiteBalanceState(
                preset: wbPreset(kelvin: wb.whiteBalance, range: range),
                kelvin: Level(Double(wb.whiteBalance), range: range, step: 100),
                tint: tintLevel
            )
        }

        // ND filter: the camera's own stops (URSA Cine 12K LF: clear, 2, 4, 6), never a made-up list. That list used
        // to be read from a key the API doesn't send, so an URSA Cine would have offered ND 8–64 and been refused.
        if let nd = p.ndFilter {
            let currentLabel = Stops.ndLabel(nd.stop)
            let validStops = p.supportedNDFilters?.stops?.map { Stops.ndLabel($0) } ?? [currentLabel]
            state.nd = NDState(preset: Choice(currentLabel, options: validStops))
        }

        // Iris: only a lens the camera can drive, and read-only while auto exposure drives it
        if let fstop = p.iris?.apertureStop, let desc = p.irisDescription, desc.controllable != false {
            state.iris = Choice(fstop, options: irisOptions(from: desc), isWritable: p.iris?.continuousApertureAutoExposure != true)
        }

        // Battery, and what's powering it when it isn't one (/camera/power source: Battery, AC, Fiber, USB, POE)
        if let power = p.power {
            state.batteryPercent = power.batteries?.first?.chargeRemainingPercent
            state.batteryVolts = volts(power.milliVolt ?? power.batteries?.first?.milliVolt)
            state.powerSource = powerSourceLabel(power.source)
        }

        // Media remaining
        if let ws = p.workingset {
            let disks = ws.workingset?.compactMap { $0 } ?? []
            let active = disks.first { $0.activeDisk == true } ?? disks.first
            state.mediaRemainingMinutes = active?.remainingRecordTime.map { $0 / 60 }
        }

        if let range = p.dynamicRange?.dynamicRange {
            state.dynamicRange = Choice(range, options: p.supportedDynamicRanges?.supportedDynamicRanges ?? [range])
        }

        // LUT on/off and false color: the first display's here; the backend widens them to every output.
        if let lut = p.displayLUT {
            state.look = Choice(lut.enabled, options: [false, true])
        }

        // False color (first display; REST API)
        if let fc = p.falseColor {
            state.falseColor = Choice(fc.enabled, options: [false, true])
        }

        // Color bars (REST API)
        if let cb = p.colorBars {
            state.colorBars = Choice(cb.enabled, options: [false, true])
        }

        if let slate = p.slate { applySlate(slate, to: &state) }

        // Playback (REST API). Always offered on Blackmagic cameras.
        state.playback = buildPlaybackState(
            transport: p.transport,
            playing: p.playing,
            clipIndex: p.clipIndex,
            timeline: p.timeline
        )

        return state
    }

    static func buildPlaybackState(
        transport: TransportResponse?,
        playing: Bool?,
        clipIndex: ClipIndexResponse?,
        timeline: TimelineResponse?
    ) -> PlaybackState {
        let isPlaying = transport?.mode == "Output" && playing == true

        // Clip info from clipIndex + timeline
        let clipIdx = clipIndex?.clipIndex  // 0-based
        let clips = timeline?.clips ?? []
        let clipNum = clipIdx.map { $0 + 1 }
        let clipCount = clips.isEmpty ? nil : clips.count
        // The timeline only has numeric ids, not display names; clip name is not available via REST.
        let clipName: String? = nil

        // stop is pause here (POST stop holds the frame), so the play/pause button covers it. Live | Review is the
        // transport mode, InputPreview or Output, as the FX3's switch.
        let caps = PlaybackCapabilities(
            playPause: true,
            stop: false,
            nextPrevious: true,
            seek: true,
            fastForwardRewind: false,
            recReview: false,
            review: true,
            goToClip: true  // the Clips window: a seek to the clip's start on the playback list
        )

        return PlaybackState(
            isPlaying: isPlaying,
            inReview: transport.map { $0.mode == "Output" },
            clipName: clipName,
            clipNumber: clipNum,
            clipCount: clipCount,
            position: nil,  // frame-position → seconds needs fps, resolved in the backend
            duration: nil,
            capabilities: caps
        )
    }

    // MARK: - WebSocket patch

    static func applyEvent(
        property: String,
        value: Any,
        to state: inout CameraState
    ) {
        // The one property that is a bare value, not an object.
        if property == "/transports/0/play" {
            if let playing = value as? Bool, var pb = state.playback {
                pb.isPlaying = playing
                state.playback = pb
            }
            return
        }
        guard let dict = value as? [String: Any] else { return }

        switch property {
        case "/transports/0":
            if let mode = dict["mode"] as? String {
                let inOutput = mode == "Output"
                if var pb = state.playback {
                    // Speed comes from /transports/0/playback; out of Output nothing plays.
                    if !inOutput { pb.isPlaying = false; pb.latestTakeMissing = false }
                    pb.inReview = inOutput
                    state.playback = pb
                }
            }

        case "/transports/0/clipIndex":
            if var pb = state.playback {
                if let idx = dict["clipIndex"] as? Int {
                    pb.clipNumber = idx + 1
                } else {
                    pb.clipNumber = nil
                }
                state.playback = pb
            }

        case "/timelines/0":
            if var pb = state.playback {
                if let clips = dict["clips"] as? [[String: Any]] {
                    pb.clipCount = clips.isEmpty ? nil : clips.count
                }
                state.playback = pb
            }

        case "/transports/0/record":
            if let recording = dict["recording"] as? Bool {
                state.recording.state = recording ? .recording : .idle
                // Only the state a REC request asked for answers it: the value in a subscription's answer, or an
                // unchanged one, isn't a confirmation.
                if state.recording.request == (recording ? .start : .stop) { state.recording.request = nil }
            }

        case "/video/iso":
            if let iso = dict["iso"] as? Int {
                let opts = state.iso?.options ?? [iso]
                state.iso = Choice(iso, options: opts)
            }

        case "/video/supportedISOs":
            if let arr = dict["supportedISOs"] as? [Int] {
                let current = state.iso?.value ?? arr.first ?? 0
                state.iso = Choice(current, options: arr)
            }

        case "/video/whiteBalance":
            if let kelvin = dict["whiteBalance"] as? Int {
                guard var wb = state.whiteBalance else { return }
                wb.kelvin.value = Double(kelvin)
                wb.kelvin.pending = nil
                wb.preset = wbPreset(kelvin: kelvin, range: wb.kelvin.range)
                state.whiteBalance = wb
            }

        case "/video/whiteBalance/description":
            if let inner = dict["whiteBalance"] as? [String: Any],
               let minK = inner["min"] as? Int, let maxK = inner["max"] as? Int {
                guard var wb = state.whiteBalance else { return }
                wb.kelvin.range = Double(minK)...Double(maxK)
                wb.preset = wbPreset(kelvin: Int(wb.kelvin.value), range: wb.kelvin.range)
                state.whiteBalance = wb
            }

        case "/video/whiteBalanceTint":
            if let tint = dict["whiteBalanceTint"] as? Int {
                guard var wb = state.whiteBalance else { return }
                wb.tint?.value = Double(tint)
                wb.tint?.pending = nil
                state.whiteBalance = wb
            }

        case "/video/whiteBalanceTint/description":
            if let inner = dict["whiteBalanceTint"] as? [String: Any],
               let minT = inner["min"] as? Int, let maxT = inner["max"] as? Int {
                guard var wb = state.whiteBalance else { return }
                wb.tint?.range = Double(minT)...Double(maxT)
                state.whiteBalance = wb
            }

        case "/video/ndFilter":
            if let stop = dict["stop"] as? Double {
                let label = Stops.ndLabel(stop)
                let opts = state.nd?.preset.options ?? [label]
                state.nd = NDState(preset: Choice(label, options: opts))
            }

        case "/video/supportedNDFilters":
            if let arr = (dict["supportedStops"] ?? dict["supportedNDFilters"]) as? [Double] {
                let labels = arr.map { Stops.ndLabel($0) }
                let cur = state.nd?.preset.value ?? labels.first ?? Stops.ndLabel(0)
                state.nd = NDState(preset: Choice(cur, options: labels))
            }

        case "/system/codecFormat":
            if let codec = dict["codec"] as? String, let container = dict["container"] as? String {
                let label = "\(codec) / \(container)"
                let opts = state.fileFormat?.options ?? [label]
                state.fileFormat = Choice(label, options: opts)
            }

        case "/lens/iris":
            // A lens the camera can't drive has no iris tile; its numbers mean nothing.
            if state.iris != nil, let fstop = dict["apertureStop"] as? Double {
                state.iris = Choice(fstop, options: state.iris?.options ?? [fstop],
                                    isWritable: dict["continuousApertureAutoExposure"] as? Bool != true)
            }

        case "/lens/iris/description":
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let desc = try? JSONDecoder().decode(IrisDescriptionResponse.self, from: data) {
                if desc.controllable == false {
                    state.iris = nil
                } else {
                    // A lens just fitted: its aperture comes with the backend's read of /lens/iris (`lensFitted`).
                    let options = irisOptions(from: desc)
                    state.iris = Choice(state.iris?.value ?? options.first ?? 0, options: options,
                                        isWritable: state.iris?.isWritable ?? true)
                }
            }

        case "/media/workingset":
            if let slots = dict["workingset"] as? [Any] {
                let disks = slots.compactMap { $0 as? [String: Any] }
                let active = disks.first { $0["activeDisk"] as? Bool == true } ?? disks.first
                state.mediaRemainingMinutes = (active?["remainingRecordTime"] as? Int).map { $0 / 60 }
            }

        case "/camera/power":
            if let batteries = dict["batteries"] as? [[String: Any]] {
                state.batteryPercent = batteries.first?["chargeRemainingPercent"] as? Int
            }
            if let source = dict["source"] as? String { state.powerSource = powerSourceLabel(source) }
            if let milliVolt = dict["milliVolt"] as? Int ?? (dict["batteries"] as? [[String: Any]])?.first?["milliVolt"] as? Int {
                state.batteryVolts = volts(milliVolt)
            }

        case "/camera/colorBars":
            if let enabled = dict["enabled"] as? Bool {
                state.colorBars = Choice(enabled, options: [false, true])
            }

        case "/camera/tallyStatus":
            if let status = dict["status"] as? String { state.tally = tally(status) }

        case "/lens/focus/description":
            // One-shot autofocus needs a lens the camera can focus (a 403 otherwise, LensControl).
            state.canAutoFocus = dict["controllable"] as? Bool == true

        case "/slates/nextClip":
            if let slate = decode(dict, as: SlateResponse.self) { applySlate(slate, to: &state) }

        case "/system/dynamicRange":
            if let range = dict["dynamicRange"] as? String {
                state.dynamicRange = Choice(range, options: state.dynamicRange?.options ?? [range])
            }

        case "/system/supportedDynamicRanges":
            if let ranges = dict["supportedDynamicRanges"] as? [String], let current = state.dynamicRange?.value {
                state.dynamicRange = Choice(current, options: ranges)
            }

        default:
            break
        }
    }


    /// An output as its socket is labeled: "MainSDI" is the SDI out.
    static func outputName(_ id: String) -> String {
        switch id {
        case "FrontUSBC": "Front USB-C"
        case "RearUSBC": "Rear USB-C"
        case "MainSDI": "SDI"
        default: id
        }
    }

    /// Off-speed rates offered: the usual ones within the format's range, its top, and the current one.
    static func offSpeedRates(min low: Double, max high: Double, current: Double) -> [Double] {
        let usual: [Double] = [12, 15, 18, 20, 24, 25, 30, 36, 40, 45, 48, 50, 60, 72, 75, 80, 90, 96, 100, 110, 120]
        return Array(Set(usual.filter { (low...high).contains($0) } + [high, current])).sorted()
    }

    // MARK: - Helpers

    /// Tiles' white balance presets, the same on every camera (`WhiteBalancePresets`), within the camera's range; then
    /// Auto. (The PYXIS's own were 3200, 4000, 4500, 5600 and 6500K.) The value is the Kelvin set now, so a preset it
    /// matches is the one ticked.
    static func wbPreset(kelvin: Int, range: ClosedRange<Double>) -> Choice<String> {
        Choice("\(kelvin)K", options: WhiteBalancePresets.labels(within: range) + ["Auto"])
    }

    /// The ISOs a model's sensor is native at, as Blackmagic's specifications give them (the API doesn't say):
    /// PYXIS 12K "Native ISO: 800" (blackmagicdesign.com/products/blackmagicpyxis/techspecs), PYXIS 6K "dual native
    /// ISO of 400 and 3,200" (PYXIS manual, Camera 10.1). Other models: none marked.
    static func nativeISOs(model: String?) -> [Int] {
        switch model {
        case "PYXIS 12K": [800]
        case "PYXIS 6K": [400, 3200]
        default: []
        }
    }

    /// The Naming tile from the slate: the camera letter, which can be set, and the reel, which can't. A refusal shown in
    /// the Naming sheet stays until the next change.
    static func applySlate(_ slate: SlateResponse, to state: inout CameraState) {
        state.clipName = slate.clip?.clipName.flatMap { $0 == "Next Clip" ? nil : $0 }
        state.fileNaming = FileNaming(cameraID: slate.project?.camera.map { Choice($0, options: cameraLetters) },
                                      reel: slate.clip?.reel.map { Level(Double($0), range: 1...999, step: 1, isWritable: false) },
                                      failure: state.fileNaming?.failure)
    }

    static let cameraLetters = (65...90).map { String(UnicodeScalar(UInt8($0))) }

    /// A pushed value (JSONSerialization's) as one of the response types.
    static func decode<T: Decodable>(_ value: Any, as type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Frame rate, codec and resolution from the current format, with the choices the matching supported format
    /// (its recording area) allows. Without the supported list, the current values alone.
    static func applyFormat(_ fmt: FormatResponse, supported: [SupportedFormat], to state: inout CameraState) {
        let entry = SupportedFormat.matching(fmt, in: supported)
        if let fr = fmt.frameRate {
            var fps = FrameRateState(project: Choice(fr, options: entry?.frameRates ?? standardFrameRates()),
                                     variableName: "Off-speed")
            if let on = fmt.offSpeedEnabled { fps.variable = Choice(on, options: [false, true]) }
            if let rate = fmt.offSpeedFrameRate,
               let low = entry?.minOffSpeedFrameRate ?? fmt.minOffSpeedFrameRate,
               let high = entry?.maxOffSpeedFrameRate ?? fmt.maxOffSpeedFrameRate {
                fps.variableRate = Choice(rate, options: offSpeedRates(min: low, max: high, current: rate))
            }
            state.frameRate = fps
        }
        if let codec = fmt.codec {
            state.fileFormat = Choice(codecLabel(codec), options: (entry?.codecs ?? [codec]).map(codecLabel))
        }
        if let res = fmt.recordResolution {
            let label = entry?.label ?? fmt.resolutionDescriptor?.description ?? resLabel(res)
            state.resolution = Choice(label, options: supported.isEmpty ? [label] : supported.map(\.label))
        }
    }

    /// Shutter mode, angle and speed from the last /video/shutter, its measurement and the supported values. The
    /// camera reports only the current measurement's value, so the other control keeps its last one (it isn't shown).
    static func applyShutter(
        to state: inout CameraState,
        shutter: ShutterResponse?,
        measurement: ShutterMeasurementResponse?,
        supported: SupportedShuttersResponse?
    ) {
        let mode: ShutterMode
        if let m = measurement?.measurement {
            mode = m == "ShutterAngle" ? .angle : .speed
        } else if shutter?.shutterAngle != nil {
            mode = .angle
        } else {
            mode = .speed
        }

        state.shutterMode = Choice(mode, options: [.angle, .speed])

        // Read-only while the camera's auto exposure drives the shutter, as the iris is (the camera turns a set down).
        let auto = shutter?.continuousShutterAutoExposure == true
        if let angle = shutter?.shutterAngle.map({ $0 / 100 }) ?? state.shutterAngle?.value {
            let opts = supported?.shutterAngles?.map { $0 / 100 } ?? [angle]
            state.shutterAngle = Choice(angle, options: opts, isWritable: mode == .angle && !auto)
        }

        if let label = shutter?.shutterSpeed.map(shutterSpeedLabel) ?? state.shutterSpeed?.value {
            let opts = supported?.shutterSpeeds?.map(shutterSpeedLabel) ?? [label]
            state.shutterSpeed = Choice(label, options: opts, isWritable: mode == .speed && !auto)
        }
    }

    /// The Battery tile's word for a /camera/power source that isn't a battery. "AC" is these cameras' DC input (our
    /// PYXIS on its adapter or a power plate on its 2-pin input read "AC" at 17.9 V), so "DC", as a Sony on DC reads;
    /// "Fiber", "USB", "PoE".
    static func powerSourceLabel(_ source: String?) -> String? {
        switch source {
        case nil, "Battery": nil
        case "AC": "DC"
        case "POE": "PoE"
        case let other?: other
        }
    }

    static func codecLabel(_ c: CodecEntry) -> String {
        "\(c.codec) / \(c.container)"
    }

    static func codecLabel(_ c: CodecFormatResponse) -> String {
        "\(c.codec ?? "?") / \(c.container ?? "?")"
    }

    static func resLabel(_ r: RecordResolution) -> String {
        "\(r.width)x\(r.height)"
    }

    /// "BRaw:8_1" → "BRAW 8:1", "BRaw:Q0" → "BRAW Q0": the way the camera's menu writes them.
    static func codecLabel(_ raw: String) -> String {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return raw }
        let family = parts[0].uppercased()
        return "\(family) \(parts[1].replacingOccurrences(of: "_", with: ":"))"
    }

    static func shutterSpeedLabel(_ speed: Int) -> String {
        "1/\(speed)"
    }

    /// The lens's range in third stops, as a lens barrel marks them (f-numbers are geometric, so not evenly spaced).
    static func irisOptions(from desc: IrisDescriptionResponse) -> [Double] {
        guard let min = desc.apertureStop?.min, let max = desc.apertureStop?.max, max > min else { return [] }
        let inside = Stops.fNumbers.filter { $0 > min + 0.05 && $0 < max - 0.05 }
        return [min] + inside + [max]
    }

    static func standardFrameRates() -> [String] {
        ["23.98", "24", "25", "29.97", "30", "47.95", "48", "50", "59.94", "60"]
    }
}

// MARK: - REST response models

struct ProductResponse: Decodable, Sendable {
    var productName: String?
    var deviceName: String?
    var softwareVersion: String?
}

struct FormatResponse: Decodable, Sendable {
    var frameRate: String?
    var offSpeedEnabled: Bool?
    var offSpeedFrameRate: Double?
    var maxOffSpeedFrameRate: Double?
    var minOffSpeedFrameRate: Double?
    var recordResolution: RecordResolution?
    var sensorResolution: RecordResolution?
    var resolutionDescriptor: ResolutionDescriptor?
    var codec: String?
}

struct RecordResolution: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
}

struct ResolutionDescriptor: Decodable, Sendable {
    var description: String?
    var group: String?
    var aspectRatio: String?
}

/// PUT /system/format: the camera takes only a whole format ("Invalid format" for one field alone), so a change is
/// the current format with that field replaced.
struct FormatRequest: Encodable, Sendable {
    var codec: String?
    var frameRate: String?
    var offSpeedEnabled: Bool?
    var offSpeedFrameRate: Double?
    var recordResolution: RecordResolution?
    var sensorResolution: RecordResolution?

    init(_ f: FormatResponse) {
        codec = f.codec
        frameRate = f.frameRate
        offSpeedEnabled = f.offSpeedEnabled
        offSpeedFrameRate = f.offSpeedFrameRate
        recordResolution = f.recordResolution
        sensorResolution = f.sensorResolution
    }
}

/// One entry of GET /system/supportedFormats: a recording area, and the codecs and frame rates allowed in it.
struct SupportedFormat: Decodable, Sendable {
    var recordResolution: RecordResolution
    var sensorResolution: RecordResolution?
    var resolutionDescriptor: ResolutionDescriptor?
    var codecs: [String]
    var frameRates: [String]
    var minOffSpeedFrameRate: Double?
    var maxOffSpeedFrameRate: Double?

    /// "9K 16:9", as the camera's menu has it.
    var label: String {
        resolutionDescriptor?.description ?? BlackmagicRESTStateMapper.resLabel(recordResolution)
    }

    /// The entry for the current format: same recording size, and the same sensor window where both say.
    static func matching(_ f: FormatResponse, in list: [SupportedFormat]) -> SupportedFormat? {
        list.first { $0.recordResolution == f.recordResolution
            && ($0.sensorResolution == nil || f.sensorResolution == nil || $0.sensorResolution == f.sensorResolution) }
    }

    /// `rate` if allowed, else the allowed rate closest to it (60 in a 12K area that stops at 30 becomes 30).
    static func nearestFrameRate(to rate: String, in rates: [String]) -> String? {
        guard !rates.contains(rate), let value = Double(rate) else { return rate }
        return rates.min { abs((Double($0) ?? 0) - value) < abs((Double($1) ?? 0) - value) }
    }

    /// `codec` if allowed, else the closest of the same kind: constant bitrate "BRaw:8_1" in a 4K area that stops at
    /// 6:1 becomes "BRaw:6_1", constant quality "BRaw:Q3" stays a Q. Not the list's first, Q0, the heaviest.
    static func nearestCodec(to codec: String, in codecs: [String]) -> String? {
        guard !codecs.contains(codec) else { return codec }
        func kind(_ c: String) -> (quality: Bool, number: Double)? {
            guard let setting = c.split(separator: ":").last else { return nil }
            if setting.hasPrefix("Q") { return Double(setting.dropFirst()).map { (true, $0) } }
            return Double(setting.split(separator: "_").first ?? "").map { (false, $0) }
        }
        guard let wanted = kind(codec) else { return codecs.first }
        let sameKind = codecs.compactMap { c in kind(c).map { (c, $0) } }.filter { $0.1.quality == wanted.quality }
        return sameKind.min { abs($0.1.number - wanted.number) < abs($1.1.number - wanted.number) }?.0 ?? codecs.first
    }
}

struct SupportedFormatsResponse: Decodable, Sendable {
    var supportedFormats: [SupportedFormat]
}

/// GET /slates/nextClip, the parts the app uses (SlateControl.yaml, Camera 10.1).
struct SlateResponse: Decodable, Sendable {
    var clip: Clip?
    var project: Project?
    struct Clip: Decodable, Sendable {
        var clipName: String?
        var reel: Int?
    }
    struct Project: Decodable, Sendable {
        var camera: String?
    }
}

/// PUT /slates/nextClip: one field (partial updates are allowed).
struct SlateUpdate: Encodable, Sendable {
    var clip: Clip?
    var project: Project?
    struct Clip: Encodable, Sendable { var reel: Int }
    struct Project: Encodable, Sendable { var camera: String }
}

/// GET /transports/0/timecode: "display" is what the camera shows (time of day, or the clip's while recording).
struct TimecodeResponse: Decodable, Sendable {
    var display: String?
}

struct CodecFormatResponse: Decodable, Sendable {
    var codec: String?
    var container: String?
}

struct SupportedCodecFormatsResponse: Decodable, Sendable {
    var codecs: [CodecEntry]?
}

struct CodecEntry: Decodable, Sendable {
    var codec: String
    var container: String
}

struct ISOResponse: Decodable, Sendable {
    var iso: Int
}

struct SupportedISOsResponse: Decodable, Sendable {
    var supportedISOs: [Int]?
}

struct ShutterResponse: Decodable, Sendable {
    var shutterAngle: Double?
    var shutterSpeed: Int?
    var continuousShutterAutoExposure: Bool?
}

/// GET /video/shutter/measurement: `{"measurement": "ShutterAngle"}` or "ShutterSpeed".
struct ShutterMeasurementResponse: Decodable, Sendable {
    var measurement: String?
}

struct SupportedShuttersResponse: Decodable, Sendable {
    var shutterAngles: [Double]?
    var shutterSpeeds: [Int]?
}

struct WhiteBalanceResponse: Decodable, Sendable {
    var whiteBalance: Int
}

struct WhiteBalanceDescriptionResponse: Decodable, Sendable {
    var whiteBalance: WBRange
    struct WBRange: Decodable, Sendable {
        var min: Int
        var max: Int
    }
}

struct WhiteBalanceTintResponse: Decodable, Sendable {
    var whiteBalanceTint: Int
}

struct WhiteBalanceTintDescriptionResponse: Decodable, Sendable {
    var whiteBalanceTint: TintRange
    struct TintRange: Decodable, Sendable {
        var min: Int
        var max: Int
    }
}

struct NDFilterResponse: Decodable, Sendable {
    var stop: Double
}

/// GET /video/supportedNDFilters: `{"supportedStops": [0, 2, 4, 6]}` (REST API document, Video Control API; the 10.1
/// YAML says the same). `supportedNDFilters` is read too, in case a camera answers with the endpoint's name.
struct SupportedNDFiltersResponse: Decodable, Sendable {
    var supportedStops: [Double]?
    var supportedNDFilters: [Double]?
    var stops: [Double]? { supportedStops ?? supportedNDFilters }
}

struct IrisResponse: Decodable, Sendable {
    var apertureStop: Double?
    var normalised: Double?
    /// Auto exposure drives the aperture: the camera refuses a set (403), so the tile shows it without changing it.
    var continuousApertureAutoExposure: Bool?
}

/// GET /lens/iris/description: `{"apertureStop": {"min", "max"}, "controllable"}` (PYXIS 12K, Camera 10.1).
struct IrisDescriptionResponse: Decodable, Sendable {
    var controllable: Bool?
    var apertureStop: StopRange?
    struct StopRange: Decodable, Sendable {
        var min: Double
        var max: Double
    }
}

struct WorkingSetResponse: Decodable, Sendable {
    var workingset: [WorkingSetEntry?]?
}

struct WorkingSetEntry: Decodable, Sendable {
    var activeDisk: Bool?
    var volume: String?
    var deviceName: String?
    var remainingRecordTime: Int?
    var remainingSpace: Int?
    var clipCount: Int?
}

struct PowerResponse: Decodable, Sendable {
    var source: String?
    var milliVolt: Int?
    var batteries: [BatteryEntry]?

    struct BatteryEntry: Decodable, Sendable {
        var milliVolt: Int?
        var chargeRemainingPercent: Int?
        var statusFlags: [String]?
    }
}

struct RecordResponse: Decodable, Sendable {
    var recording: Bool
}

struct MonitoringDisplayResponse: Decodable, Sendable {
    var displays: [String]
}

extension MonitorOverlay {
    /// Its name in /monitoring/{output}/{leaf}.
    var restLeaf: String {
        switch self {
        case .lut: "displayLUT"
        case .frameGuides: "frameGuide"
        default: rawValue
        }
    }
}

struct DynamicRangeResponse: Decodable, Sendable {
    var dynamicRange: String?
}

struct SupportedDynamicRangesResponse: Decodable, Sendable {
    var supportedDynamicRanges: [String]?
}

/// GET /monitoring/zebra: the highlight zebra's level is 75–100, or "None".
struct ZebraResponse: Decodable, Sendable {
    var highlight: Highlight?
    struct Highlight: Decodable, Sendable {
        var enabled: Bool?
        var level: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
            level = try? c.decodeIfPresent(Int.self, forKey: .level)
        }
        private enum CodingKeys: String, CodingKey { case enabled, level }
    }
}

struct FrameGuideRatioResponse: Decodable, Sendable {
    var ratio: String?
}

struct FrameGuidePresetsResponse: Decodable, Sendable {
    var presets: [String]?
}

struct MonitoringEnabledResponse: Decodable, Sendable {
    var enabled: Bool
}

/// GET /camera/tallyStatus: `{"status": "None" | "Preview" | "Program"}` (CameraControl).
struct TallyStatusResponse: Decodable, Sendable {
    var status: String?
}

extension BlackmagicRESTStateMapper {
    /// The camera's tally as the BURANO's lamps read in Tiles (and over the Control API): Program is red, Preview green.
    static let tallyStatuses = ["Off": "None", "Green": "Preview", "Red": "Program"]

    /// `CameraState.tally` from the camera's status; an unknown status shows as itself.
    static func tally(_ status: String) -> Choice<String> {
        let shown = tallyStatuses.first { $0.value == status }?.key ?? status
        return Choice(shown, options: ["Off", "Green", "Red"])
    }

    /// The voltage the camera runs on (/camera/power's `milliVolt`, else its battery's), in volts. On a DC input it's
    /// all there is: a power plate on a PYXIS's 2-pin input sends no battery data, so there's no percentage.
    static func volts(_ milliVolt: Int?) -> Double? {
        milliVolt.flatMap { $0 > 0 ? Double($0) / 1000 : nil }
    }
}

// MARK: - Playback REST responses (REST API)

struct TransportResponse: Decodable, Sendable {
    var mode: String?
}

struct PlaybackResponse: Codable, Sendable {
    var type: String?
    var loop: Bool?
    var singleClip: Bool?
    var speed: Double?
    var position: Int?
    init() {}
}

struct ClipIndexResponse: Decodable, Sendable {
    var clipIndex: Int?
}

struct TimelineResponse: Decodable, Sendable {
    var clips: [TimelineClip]?
}

/// `GET /clips`, as far as each clip's id and file: every clip on the active disk, on the playback list or not.
struct ClipList: Decodable, Sendable {
    struct Clip: Decodable, Sendable {
        var clipUniqueId: Int?
        var filePath: String?
    }
    var clips: [Clip]?

    /// A clip's name as the Clips window shows it: its file's, without the folder or extension
    /// ("A001_11141530_C003.braw" → "A001_11141530_C003").
    static func clipName(_ filePath: String) -> String? {
        let file = (filePath as NSString).lastPathComponent
        let name = (file as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }
}

struct TimelineClip: Decodable, Sendable {
    var clipUniqueId: Int?
    var frameCount: Int?
    var timelineIn: Int?

    private enum CodingKeys: String, CodingKey {
        case clipUniqueId, frameCount, timelineIn
    }

    init(uniqueId: Int, frameCount: Int?, timelineIn: Int?) {
        self.clipUniqueId = uniqueId
        self.frameCount = frameCount
        self.timelineIn = timelineIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clipUniqueId = try c.decodeIfPresent(Int.self, forKey: .clipUniqueId)
        frameCount = try c.decodeIfPresent(Int.self, forKey: .frameCount)
        // timelineIn may be a string (timecode) or int (frame number) depending on version
        if let i = try? c.decodeIfPresent(Int.self, forKey: .timelineIn) {
            timelineIn = i
        } else {
            timelineIn = nil
        }
    }
}

