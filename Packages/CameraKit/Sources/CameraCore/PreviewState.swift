import Foundation

// Edit mode shows a camera that isn't connected as a demo of itself, so a page can be laid out, its tiles added and
// their outputs set, with the camera off. Only in edit mode, where tiles take no taps, and only drawn: the camera's
// own controller, its saved profile and the Control API never see the stand-in. Test Mode makes the stand-in a working
// demo on every page, so the page can be used as well as laid out; still nothing reaches the camera.

extension MockCameraBackend {
    /// A PYXIS 12K as the backend reads it: off-speed on, some overlays on, SDI on clean feed. The snapshot
    /// tool's PYXIS, and edit mode's stand-in for a Blackmagic camera that isn't connected.
    public static func pyxisSampleState(now: Date = Date()) -> CameraState {
        var s = CameraState()
        s.connection = .connected
        s.make = .blackmagic
        s.model = "PYXIS 12K"
        s.recording = RecordingControl(state: .idle)
        s.timecode = TimecodeClock(frames: 15 * 3600 * 24, anchor: now, rate: 24, fps: 24, isRunning: true)
        s.iso = Choice(800, options: [125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200])
        s.nativeISOs = [800]
        s.shutterMode = Choice(.angle, options: [.angle, .speed])
        s.shutterAngle = Choice(180, options: [11.25, 15, 22.5, 30, 37.5, 45, 60, 72, 75, 90, 108, 120, 144, 150, 172.8, 180,
                                              216, 270, 324, 360])
        s.frameRate = FrameRateState(project: Choice("24", options: ["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"]),
                                     variable: Choice(true, options: [false, true]),
                                     variableRate: Choice(60, options: [12, 15, 18, 20, 24, 25, 30, 36, 40, 45, 48, 50, 60, 65]),
                                     variableName: "Off-speed")
        s.whiteBalance = WhiteBalanceState(preset: Choice("5600K", options: WhiteBalancePresets.labels(within: 2500...10000) + ["Auto"]),
                                           kelvin: Level(5600, range: 2500...10000, step: 100),
                                           tint: Level(10, range: -50...50, step: 1))
        s.fileFormat = Choice("BRAW 8:1", options: ["BRAW Q0", "BRAW Q1", "BRAW Q3", "BRAW Q5", "BRAW 3:1", "BRAW 8:1",
                                                    "BRAW 12:1", "BRAW 18:1"])
        s.resolution = Choice("9K 16:9", options: ["12K 17:9", "9K 16:9", "4K 16:9"])
        s.dynamicRange = Choice("Film", options: ["Film", "Extended Video", "Video"])
        s.canGrabStill = true
        s.fileNaming = FileNaming(cameraID: Choice("A", options: (65...90).map { String(UnicodeScalar(UInt8($0))) }),
                                  reel: Level(1, range: 1...999, step: 1, isWritable: false))
        s.batteryPercent = 100
        s.mediaRemainingMinutes = 51
        s.latencyMilliseconds = 2
        s.monitoring = MonitoringState(outputs: [
            pyxisOutput("LCD", "LCD", on: [.lut, .zebra, .focusAssist, .frameGuides, .statusText]),
            pyxisOutput("FrontUSBC", "Front USB-C", on: [.lut, .frameGuides, .statusText]),
            pyxisOutput("RearUSBC", "Rear USB-C", on: [.statusText]),
            pyxisOutput("MainSDI", "SDI", on: [.lut, .cleanFeed], shows: .cinematographer),
        ], zebraLevel: Choice(95, options: [75, 80, 85, 90, 95, 100]),
           frameGuideRatio: Choice("2.39:1", options: ["2.40:1", "2.39:1", "2.35:1", "1.85:1", "16:9", "4:3", "1:1", "9:16"]))
        s.look = s.monitoring?.onEverywhere(.lut)
        s.falseColor = s.monitoring?.onEverywhere(.falseColor)
        s.colorBars = Choice(false, options: [false, true])
        s.desqueeze = Choice("None", options: ["None", "1.33x", "1.5x", "1.6x", "1.66x", "1.8x", "2.0x"])
        s.lut = Choice("Blackmagic Gen 5 Film to Extended Video.cube",
                       options: ["Blackmagic Gen 5 Film Look.cube", "Blackmagic Gen 5 Film to Extended Video.cube"])
        s.playback = PlaybackState(isPlaying: false, inReview: false, clipName: nil, clipNumber: 2, clipCount: 48,
                                   position: nil, duration: nil,
                                   capabilities: PlaybackCapabilities(playPause: true, stop: false, nextPrevious: true, seek: true,
                                                                      fastForwardRewind: false, recReview: false, review: true,
                                                                      goToClip: true))
        // Its playback list, named as a PYXIS names its files: a morning's takes from 9:12, 20 s to 3 min each.
        s.playback?.clips = (0..<48).map { (i: Int) -> PlaybackClip in
            let minutes: Int = 9 * 60 + 12 + i * 3
            let name = String(format: "A001_1114%02d%02d_C%03d", minutes / 60, minutes % 60, i + 1)
            let seconds: Int = 20 + (i * 37) % 160
            return PlaybackClip(id: i, name: name, seconds: Double(seconds))
        }
        // From the API's documentation rather than that camera: tally and two audio channels, in the API's
        // names and plausible ranges. No autofocus: its lenses are manual (the gallery's PYXIS has one that focuses).
        s.tally = Choice("Off", options: ["Off", "Green", "Red"])
        s.audioChannels = [
            AudioChannel(id: 0, input: Choice("Camera - Left", options: ["Camera - Left", "3.5mm Left - Mic", "3.5mm Left - Line"]),
                         gain: Level(30, range: 0...60, step: 1), lowCut: Choice(false, options: [false, true])),
            AudioChannel(id: 1, input: Choice("Camera - Right", options: ["Camera - Right", "3.5mm Right - Mic", "3.5mm Right - Line"]),
                         gain: Level(30, range: 0...60, step: 1), lowCut: Choice(false, options: [false, true])),
        ]
        return s
    }

    /// An output that reports every overlay a PYXIS has (not a VENICE's audio meters), with `on` switched on, and its
    /// status text showing `shows` (as a PYXIS's outputs all do).
    static func pyxisOutput(_ id: String, _ name: String, on: Set<MonitorOverlay>,
                            shows: StatusTextContent = .meters) -> MonitorOutput {
        MonitorOutput(id: id, name: name, overlays: Dictionary(uniqueKeysWithValues: MonitorOverlay.allCases.filter { $0 != .audioMeters }.map {
            ($0, Choice(on.contains($0), options: [false, true]))
        }), statusTextContent: Choice(shows, options: shows.pair))
    }
}

extension DashboardStore {
    /// What edit mode draws for a camera: a demo of itself when it isn't connected (sample values for its model, its
    /// letter and color, "demo" after the model), otherwise nil and the camera itself. A demo camera is one already.
    /// The stand-in has a backend that never connects and is never started: nothing it's asked goes anywhere. In Test
    /// Mode it's a working demo instead (`MockCameraBackend` from the same values), its tiles changing its values and
    /// nothing else: still never the camera, its saved profile or the Control API.
    public func previewController(for camera: CameraController) -> CameraController? {
        guard !camera.isDemo, !camera.state.connection.isControllable, let saved = savedCamera(camera.id) else { return nil }
        if let cached = previews[camera.id], cached.slot == camera.slot, cached.connection == saved.connection,
           cached.profile == camera.lastSeen, cached.working == testMode {
            return cached.controller
        }
        previews[camera.id]?.controller.disconnect()
        let state = Self.previewState(saved, lastSeen: camera.lastSeen)
        let backend: any CameraBackend = testMode
            ? MockCameraBackend(state: state, label: camera.slot.label) : UnavailableBackend(reason: "preview")
        let controller = CameraController(slot: camera.slot, backend: backend, initialState: state, lastSeen: camera.lastSeen)
        controller.isDemo = true
        if testMode { controller.start() }
        previews[camera.id] = CameraPreview(slot: camera.slot, connection: saved.connection, profile: camera.lastSeen,
                                            working: testMode, controller: controller)
        return controller
    }

    /// The camera the dashboard draws and works for `camera`: itself, or in Test Mode its working demo while it isn't
    /// connected. Edit mode always draws an offline camera's demo (`previewController(for:)`).
    public func shownController(for camera: CameraController, editing: Bool = false) -> CameraController {
        guard editing || testMode else { return camera }
        return previewController(for: camera) ?? camera
    }

    /// `shownController` by id: for the sheets a tile opens (Monitoring, Clip Naming), so they work on what it showed.
    public func shownCamera(_ id: UUID) -> CameraController? {
        camera(id).map { shownController(for: $0) }
    }

    /// Sample values for the camera's model: a PYXIS 12K for a Blackmagic camera, otherwise the Sony body it reported
    /// (an FX3 until it has). Its model, and the outputs it reported, replace the sample's.
    static func previewState(_ saved: SavedCamera, lastSeen: CameraProfile?) -> CameraState {
        let blackmagic = saved.connection.blackmagic != nil || saved.connection.demoBody?.isBlackmagic == true
            || lastSeen?.make == .blackmagic
        let venice = isVenice(saved, lastSeen: lastSeen)
        let arri = isArri(saved, lastSeen: lastSeen)
        var state = venice
            ? MockCameraBackend.veniceSampleState(label: saved.slot.label)
            : arri
            ? MockCameraBackend.arriSampleState(body: saved.connection.demoBody
                ?? lastSeen?.model.flatMap(MockBody.init(rawValue:)) ?? .alexaMini, label: saved.slot.label)
            : blackmagic
                ? MockCameraBackend.pyxisSampleState()
                : MockCameraBackend.sampleState(body: lastSeen?.model.flatMap(MockBody.init(rawValue:)) ?? .fx3,
                                                 label: saved.slot.label)
        if let model = lastSeen?.model { state.model = model }
        if let outputs = lastSeen?.outputs, !outputs.isEmpty, var monitoring = state.monitoring {
            let sample = monitoring.outputs
            monitoring.outputs = outputs.map { output in
                sample.first { $0.id == output.id }.map { MonitorOutput(id: $0.id, name: output.name, overlays: $0.overlays) }
                    ?? MockCameraBackend.pyxisOutput(output.id, output.name, on: [])
            }
            state.monitoring = monitoring
            state.look = monitoring.onEverywhere(.lut)
            state.falseColor = monitoring.onEverywhere(.falseColor)
        }
        return state
    }

    /// The tiles Add Tile lists for a camera: those it has controls for (no adding de-squeeze to an FX3). One that isn't
    /// connected also lists what its demo has, so a tile it gained in a newer build (Clean Feed) can be added before it
    /// next connects. Not `.look` or `.format`: they only exist so old saved layouts still load (`.look` was a second
    /// "View Assist", `.format` a read-only copy of Codec). HaLow only once there's a node.
    public func tileKinds(for camera: CameraController) -> [WidgetKind] {
        let preview = previewController(for: camera)
        return WidgetKind.allCases.filter {
            $0 != .look && $0 != .format && ($0 != .haLow || !haLowNodes.isEmpty)
                // Record All needs 2+ cameras on the current page to do anything.
                && ($0 != .recordAll || visibleCameras.count > 1)
                && (camera.offers($0) || preview?.state.offers($0) == true)
        }
    }
}

/// A camera's stand-in for edit mode and Test Mode, kept while its letter, color, connection and last report are the
/// same, and Test Mode hasn't been switched.
struct CameraPreview {
    var slot: CameraSlot
    var connection: CameraConnection
    var profile: CameraProfile?
    /// A working demo (Test Mode), or values that never change.
    var working: Bool
    var controller: CameraController
}

/// Test Mode's word when a camera goes live (it took over from its demo), or drops out (its demo took over).
public struct TestModeNotice: Equatable, Identifiable, Sendable {
    /// Each notice is new, even for the same camera twice.
    public let id = UUID()
    public var cameraID: UUID
    public var label: String
    public var isLive: Bool

    public init(cameraID: UUID, label: String, isLive: Bool) {
        self.cameraID = cameraID
        self.label = label
        self.isLive = isLive
    }
}
