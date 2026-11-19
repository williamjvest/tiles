import Foundation

/// Everything the dashboard can ask a camera to do. Backends ignore commands the body doesn't support.
public enum CameraCommand: Sendable, Equatable {
    case record(Bool)
    case setISO(Int)
    case setBaseISO(Int)
    case setShutterAngle(Double)
    case setShutterSpeed(String)
    case setShutterMode(ShutterMode)
    case setNDPreset(String)
    case setVariableND(Double)
    case setWhiteBalancePreset(String)
    case setKelvin(Double)
    case setTint(Double)
    case setIris(Double)
    case setFrameRateVariable(Bool)
    /// The sensor's frame rate while variable (S&Q, off-speed) is on.
    case setFrameRateVariableRate(Double)
    case setClipFlag(ClipFlag)
    case setImageFlip(Bool)
    case setColorBars(Bool)
    /// `CameraState.ndMode`: "Step" or "Variable".
    case setNDMode(String)
    /// `CameraState.tally`: "Off", "Green" or "Red".
    case setTally(String)
    /// `CameraState.call`.
    case setCall(Bool)
    /// `CameraState.colorGamut`.
    case setColorGamut(String)
    /// `CameraState.shootingMode`.
    case setShootingMode(String)
    /// `CameraState.gain`, in dB.
    case setGain(Int)
    /// `CameraState.baseSensitivity`.
    case setBaseSensitivity(String)
    /// `CameraState.steadyShot`.
    case setSteadyShot(String)
    /// `CameraState.imagerMode`.
    case setImagerMode(String)
    /// `CameraState.subjectRecognition`.
    case setSubjectRecognition(String)
    /// `CameraState.focusArea`.
    case setFocusArea(String)
    /// `CameraState.afTransitionSpeed`.
    case setAFTransitionSpeed(Int)
    /// `CameraState.afSubjectShift`.
    case setAFSubjectShift(Int)
    /// `CameraState.afAssist`.
    case setAFAssist(Bool)
    /// `CameraState.recordedLUT`.
    case setRecordedLUT(Bool)
    /// `CameraState.proxyRecording`.
    case setProxyRecording(Bool)
    /// `CameraState.ecs`, on or off.
    case setECS(Bool)
    /// `CameraState.ecs`'s frequency, stepped up (+) or down (−).
    case stepECS(Int)
    /// `CameraState.irisAuto`.
    case setIrisAuto(Bool)
    /// `CameraState.ndAuto`.
    case setNDAuto(Bool)
    /// `CameraState.isoAuto`.
    case setISOAuto(Bool)
    /// The focus or zoom motor at a signed speed (`LensDrive.maxSpeed` at most), 0 to stop. A held control renews it
    /// about every 200 ms; the backend stops the motor itself when nothing renews it for 600 ms, so a lost lift never
    /// leaves it running.
    case driveFocus(Int)
    case driveZoom(Int)
    /// Presses one of `CameraState.assignableButtons`, by its `id`, if it's pressable.
    case pressAssignable(Int)
    /// Press one of `CameraState.cameraButtons`. On a BURANO MENU is held, which opens or closes the full menu.
    case pressCameraButton(CameraBodyButton)
    /// One-shot autofocus on the middle of the picture (`CameraState.canAutoFocus`).
    case autoFocus
    /// One of `CameraState.audioChannels`, by its `id`.
    case setAudio(channel: Int, AudioSetting)
    /// What one of a VENICE's frame line sets shows of its user frame lines (`UserFrameLines`).
    case setUserFrameLines(FrameLineSet, String)
    case setFalseColor(Bool)
    case setLook(Bool)
    /// The camera's info on its HDMI output (`CameraState.hdmiInfo`): off is a clean feed. Sony.
    case setHDMIInfo(Bool)
    case setGridLines(Bool)
    /// One overlay on one monitoring output (`MonitorOutput.id`), or with nil on every output that has it.
    case setMonitorOverlay(MonitorOverlay, Bool, output: String?)
    /// What one output's status text shows (`MonitorOutput.statusTextContent`).
    case setStatusTextContent(StatusTextContent, output: String)
    /// Which frame line set one output shows (`MonitorOutput.frameLines`): a VENICE's Line A or Line B.
    case setFrameLineSet(FrameLineSet, output: String)
    case setZebraLevel(Int)
    case setFrameGuideRatio(String)
    case setDynamicRange(String)
    case setFrameRate(String)
    case setResolution(String)
    case setFileFormat(String)
    case setRecordingSetting(String)
    case setDesqueeze(String)
    case setLUT(String)
    case setFocusMode(String)
    /// Clip naming (`FileNaming`): the title prefix, camera ID letter and reel number.
    case setClipTitle(String)
    case setClipCameraID(String)
    case setClipReel(Int)
    case setClipCameraPosition(String)
    /// The camera's time display: duration (true) or timecode (false).
    case setTimecodeShowsDuration(Bool)
    case playback(PlaybackCommand)
    /// Turn on or off the camera setting that makes one output clone another (`MonitorOutput.sameAsSwitch`), so the
    /// output can be configured independently. `output` is the follower's `MonitorOutput.id` (e.g. "Sdi2").
    case setOutputFollows(Bool, output: String)
}

/// Controls that can be linked across the cameras on a page.
public enum LinkKind: String, Codable, CaseIterable, Sendable, Hashable {
    case whiteBalance, frameRate, shutter, record

    public var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .frameRate: "Frame Rate"
        case .shutter: "Shutter"
        case .record: "Record"
        }
    }

    /// Which link group a command belongs to, if any.
    public init?(_ command: CameraCommand) {
        switch command {
        case .setWhiteBalancePreset, .setKelvin, .setTint: self = .whiteBalance
        case .setFrameRate, .setFrameRateVariable, .setFrameRateVariableRate: self = .frameRate
        case .setShutterAngle, .setShutterSpeed, .setShutterMode: self = .shutter
        case .record: self = .record
        default: return nil
        }
    }

    /// Which link group a tile kind belongs to, so linked tiles can show the chain badge.
    public static func forWidget(_ kind: WidgetKind) -> LinkKind? {
        switch kind {
        case .wbPreset, .wbSliders: .whiteBalance
        case .frameRate: .frameRate
        case .shutterDial, .shutterValue: .shutter
        case .record: .record
        default: nil
        }
    }
}

/// Anything that can drive one camera: the mock today, Sony PTP 3 next, maybe Blackmagic later.
///
/// Contract:
/// - `updates` carries whole-state snapshots. It has a single consumer, the `CameraController` that owns
///   the backend.
/// - Settings may go optimistic: set `pending`, then settle to the camera-reported `value`.
/// - REC never does. It sets `recording.request` and waits for the camera to report the new state. On a
///   timeout it re-reads the recording state rather than resending, because a blind retry of a toggle can
///   stop a take.
/// - `record(Bool)` is absolute: `record(true)` means "make sure it's recording". A camera already in that
///   state must ignore it. This matters for linked REC, and because Sony's REC button is a toggle on the
///   wire: sending it to a camera that's already rolling would stop the take.
public protocol CameraBackend: AnyObject, Sendable {
    var updates: AsyncStream<CameraState> { get }
    func connect() async
    func disconnect() async
    func send(_ command: CameraCommand) async
}
