import ImageIO
import AppKit
import BlackmagicRESTBackend
import CameraCore
import DashboardUI
import SwiftUI

/// A no-op backend for static gallery renders. Never emits state; just keeps the CameraController happy.
actor GalleryNullBackend: CameraBackend {
    let updates: AsyncStream<CameraState> = AsyncStream { _ in }
    func connect() async {}
    func disconnect() async {}
    func send(_ command: CameraCommand) async {}
}

/// Renders the dashboard (or a settings screen) with preview data to a PNG, so layouts can be checked on
/// a headless Mac.
///
///     swift run dashboard-snapshot out.png [width] [height] [page name, e.g. "A+B"] [screen]
///
/// `screen` is one of:
///   - `settings`, `camera-editor`, `page-editor` — AppKit-backed forms rendered through a real window.
///   - `window` — dashboard rendered through a real window (needed for ScrollViews and menus).
///   - `edit` — dashboard in edit mode via a real window.
///   - `gallery` — one sheet showing every WidgetKind at all canonical sizes, plus state variants.
///                 Ignores width/height/page; always rendered through a real window.
///                 Respects CC_SNAPSHOT_SCALE.
///                 Usage: `dashboard-snapshot out.png 0 0 "" gallery`
///
/// The gallery, and any render with CC_SNAPSHOT_AUDIT=1, runs the alignment audit (`AlignmentAudit`): it prints each
/// tile whose captions don't line up, and exits 2 after writing the image.
@main
struct DashboardSnapshot {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        // CC_SNAPSHOT_STYLE=outline: the look before Ink (ThemeStyle.all has the names).
        if let name = ProcessInfo.processInfo.environment["CC_SNAPSHOT_STYLE"],
           let style = ThemeStyle.all.first(where: { $0.name == name }) {
            Theme.style = style
        }
        // CC_SNAPSHOT_APPEARANCE=custom: Settings → Appearance's custom colors on, at their start (white tiles, black
        // text, black); CC_SNAPSHOT_CORNER=<points>: the tiles' corner radius.
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_APPEARANCE"] == "custom" {
            ThemeStore.shared.appearance.customColors = true
        }
        if let corner = ProcessInfo.processInfo.environment["CC_SNAPSHOT_CORNER"].flatMap(Double.init) {
            ThemeStore.shared.appearance.corner = corner
        }
        // CC_SNAPSHOT_OUTLINES=<points>: Appearance's tile outlines on, that wide.
        if let width = ProcessInfo.processInfo.environment["CC_SNAPSHOT_OUTLINES"].flatMap(Double.init) {
            ThemeStore.shared.appearance.outlines = true
            ThemeStore.shared.appearance.outlineWidth = width
        }
        // CC_SNAPSHOT_TEXT_SIZE=dynamic: Settings → Appearance's Text Size, Dynamic. CC_SNAPSHOT_TEXT_SCALE=1.5: its
        // slider (1 to 1.5).
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_TEXT_SIZE"] == "dynamic" {
            ThemeStore.shared.appearance.textSize = .dynamic
        }
        if let scale = ProcessInfo.processInfo.environment["CC_SNAPSHOT_TEXT_SCALE"].flatMap(Double.init) {
            ThemeStore.shared.appearance.textScale = scale
        }
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "dashboard.png")
        let width = arguments.count > 2 ? Double(arguments[2]) ?? 1920 : 1920
        let height = arguments.count > 3 ? Double(arguments[3]) ?? 1180 : 1180
        let page = arguments.count > 4 && !arguments[4].isEmpty ? arguments[4] : nil
        let mode = arguments.count > 5 ? arguments[5] : ""
        let screen = DebugScreen(rawValue: mode)
        // CC_SNAPSHOT_STATE=<dashboard.v1 json> renders a device's saved setup instead of the demo lineup.
        let saved = ProcessInfo.processInfo.environment["CC_SNAPSHOT_STATE"].flatMap { FileManager.default.contents(atPath: $0) }
        // CC_SNAPSHOT_BLACKMAGIC=<host> connects to a real Blackmagic camera over HTTPS and renders its page with what
        // the app's backend read from it.
        var live: DashboardStore?
        if let host = ProcessInfo.processInfo.environment["CC_SNAPSHOT_BLACKMAGIC"] {
            live = blackmagicStore(host: host)
            if live == nil { FileHandle.standardError.write(Data("no connection to the camera\n".utf8)); exit(1) }
        }
        // CC_SNAPSHOT_BLACKMAGIC_LIVE=<host>: the app's own store connected to a real Blackmagic camera, live view and
        // all (with CC_SNAPSHOT_ADD=liveView and CC_SNAPSHOT_WAIT for its pictures; CC_SNAPSHOT_STREAM_TO=<relay>).
        // Its stream is ended before exit.
        if let host = ProcessInfo.processInfo.environment["CC_SNAPSHOT_BLACKMAGIC_LIVE"] {
            live = connectedBlackmagicStore(host: host, streamTo: ProcessInfo.processInfo.environment["CC_SNAPSHOT_STREAM_TO"])
            if live == nil { FileHandle.standardError.write(Data("no connection to the camera\n".utf8)); exit(1) }
        }
        // CC_SNAPSHOT_PYXIS=1: a PYXIS 12K, off-speed and overlays on, without the camera.
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_PYXIS"] != nil { live = pyxisStore() }
        // CC_SNAPSHOT_PYXIS_OFFLINE=1: that PYXIS saved with what it last reported, but not connected (edit mode draws a
        // demo of it).
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_PYXIS_OFFLINE"] != nil { live = pyxisOfflineStore() }
        // CC_SNAPSHOT_BODIES=venice2,alexaMini: those demo bodies (MockBody's case names) side by side on one page, as an
        // automatic page draws them.
        if let bodies = ProcessInfo.processInfo.environment["CC_SNAPSHOT_BODIES"] { live = bodiesStore(bodies) }
        let store = live ?? saved.flatMap { DashboardStore.preview(saved: $0, page: page) } ?? DashboardStore.preview(page: page)
        // CC_SNAPSHOT_TEST_MODE=1: Test Mode on (with CC_SNAPSHOT_PYXIS_OFFLINE, the offline PYXIS works as its demo).
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_TEST_MODE"] != nil { store.testMode = true }
        // CC_SNAPSHOT_NOTICE=live|offline: Test Mode's notice for the page's first camera.
        if let kind = ProcessInfo.processInfo.environment["CC_SNAPSHOT_NOTICE"], let camera = store.visibleCameras.first {
            store.previewTestModeNotice(TestModeNotice(cameraID: camera.id, label: camera.slot.label, isLive: kind == "live"))
        }
        // CC_SNAPSHOT_TALL=<n>: the page gets n more tiles below its own (Add Tile's placement), for Fit to Screen;
        // CC_SNAPSHOT_SCROLLS=1 turns Fit to Screen off for it.
        if let extra = ProcessInfo.processInfo.environment["CC_SNAPSHOT_TALL"].flatMap(Int.init),
           let page = store.currentPage, let camera = store.visibleCameras.first {
            store.materializeLayout(page.id)
            let kinds: [WidgetKind] = [.iso, .frameRate, .codec, .bitrate, .lut, .iris]
            for n in 0..<extra { store.addWidget(page.id, kind: kinds[n % kinds.count], cameraID: camera.id) }
            if ProcessInfo.processInfo.environment["CC_SNAPSHOT_SCROLLS"] != nil { store.setPageScrolls(page.id, true) }
        }
        // CC_SNAPSHOT_ADD=zebra,monitoring: those tiles added to the page for its first camera (Add Tile's placement).
        // kind@output sets a monitoring switch to one of the camera's outputs (falseColor@MainSDI), kind@ to every output.
        if let tiles = ProcessInfo.processInfo.environment["CC_SNAPSHOT_ADD"]?.split(separator: ","),
           let page = store.currentPage, let camera = store.visibleCameras.first {
            store.materializeLayout(page.id)
            for tile in tiles {
                let parts = tile.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
                guard let kind = WidgetKind(rawValue: parts[0]) else { continue }
                store.addWidget(page.id, kind: kind, cameraID: camera.id)
                if parts.count > 1, let id = store.addedWidgetID {
                    let output = camera.state.monitoring?.outputs.first { $0.id == parts[1] }.map(TileOutput.init)
                    store.setWidgetOutput(page.id, id, output: output)
                }
            }
        }
        // CC_SNAPSHOT_HALOW=1: three nodes found, one added by hand that doesn't answer, and a saved password.
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_HALOW"] != nil {
            store.credentials.setPassword("preview", for: haLowPasswordID)
            store.previewHaLowNodes([
                HaLowNode(address: "192.0.2.2", name: "node-2", isLocal: true, state: .polling,
                          stats: HaLowNodeStats(address: "192.0.2.2", hostname: "node-2", signalDBm: -68, noiseDBm: -95,
                                                phyRateKbps: 3500, mcsIndex: 7, channelWidthMHz: 2)),
                HaLowNode(address: "192.0.2.1", name: "node-1", state: .polling,
                          stats: HaLowNodeStats(address: "192.0.2.1", hostname: "node-1", signalDBm: -71)),
                HaLowNode(address: "192.0.2.4", name: "node-4", state: .polling,
                          stats: HaLowNodeStats(address: "192.0.2.4", hostname: "node-4", signalDBm: -88)),
                HaLowNode(address: "198.51.100.7", name: "198.51.100.7", isManual: true, state: .unreachable),
            ])
            store.haLowSettings.manualAddresses = ["198.51.100.7"]
        }
        // CC_SNAPSHOT_SHOWCASE=1: demo cameras drawn as real ones, for the App Store's screenshots.
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_SHOWCASE"] != nil { store.previewAsRealCameras() }
        // CC_SNAPSHOT_MESH=1: Add Camera's mesh list has sample devices in it (documentation addresses, RFC 5737).
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_MESH"] != nil {
            store.meshPreview = MeshDeviceScan(devices: [
                MeshDevice(ip: "192.0.2.31", mac: "02:00:00:00:01:01", hostname: "SonyImagingDevice", node: "node-1"),
                MeshDevice(ip: "192.0.2.32", mac: "7c:2e:0d:00:00:02", hostname: "camera-b", staticName: "camera-b",
                           node: "node-2"),
                MeshDevice(ip: "192.0.2.20", mac: "02:00:00:00:00:20", staticName: "monitor"),
                MeshDevice(ip: "192.0.2.150", mac: "02:00:00:00:01:50", hostname: "iPhone", node: "node-1"),
            ], problems: ["192.0.2.3": "No answer."])
        }

        let png: Data?
        let audit: String? = mode == "gallery" || ProcessInfo.processInfo.environment["CC_SNAPSHOT_AUDIT"] != nil ? "" : nil
        if mode == "gallery" {
            // Gallery: full tile reference sheet. Width and height are derived from content; use a tall canvas.
            let fx3 = DashboardStore.galleryController(body: .fx3, label: "C", color: .yellow, backend: GalleryNullBackend())
            let fx6 = DashboardStore.galleryController(body: .fx6, label: "B", color: .blue, backend: GalleryNullBackend())
            // An FX6 in Custom: gain in dB and its Low | High base, where the ISO and base ISO were.
            var custom = MockCameraBackend.sampleState(body: .fx6, label: "B")
            custom.shootingMode = Choice("Custom", options: ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
            custom.iso = nil
            custom.baseISO = nil
            custom.gain = Choice(12, options: Array(-3...30))
            custom.baseSensitivity = Choice("Low", options: ["Low", "High"])
            let fx6Custom = DashboardStore.galleryController(body: .fx6, label: "B", color: .blue,
                                                             backend: GalleryNullBackend(), state: custom)
            // An FX5 (docs/fx5-controls.md): Custom in ISO on a Low | Mid | High base, and Flexible ISO's three base
            // ISOs and three LUT outputs.
            var fx5 = MockCameraBackend.sampleState(body: .fx6, label: "F")
            fx5.model = "ILME-FX5"
            fx5.shootingMode = Choice("Custom", options: ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
            fx5.iso = Choice(5000, options: [5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200,
                                             64000, 80000, 102400, 128000, 160000, 204800, 256000, 320000, 409600])
            fx5.baseISO = nil
            fx5.gain = nil
            fx5.baseSensitivity = Choice("High", options: ["Low", "Mid", "High"])
            fx5.steadyShot = Choice("Standard", options: ["Off", "Standard", "Active", "Dynamic Active"])
            fx5.imagerMode = Choice("FF 5K 16:9", options: ["FF 5K 17:9", "FF 5K 16:9", "FFc 4.5K 17:9", "FFc 4.5K 16:9",
                                                         "S35 3.2K 16:9"])
            fx5.canAutoFocus = true
            // Autofocusing: the Autofocus tile's push grays beside AF.
            fx5.focusMode = Choice("AF", options: ["AF", "MF"])
            fx5.focusIsAuto = true
            // No button set to False Color: grayed, saying so.
            fx5.falseColor = Choice(false, options: [false, true], isWritable: false)
            fx5.falseColorHint = "Assign a button"
            // A flat battery on USB-C power (batteryPercent 0, powerSource "USB"); and the camera warning it's hot.
            fx5.batteryPercent = 0
            fx5.powerSource = "USB"
            fx5.alerts = ["Overheating"]
            let fx5Custom = DashboardStore.galleryController(body: .fx6, label: "F", color: .orange,
                                                             backend: GalleryNullBackend(), state: fx5)
            fx5.shootingMode = Choice("Flexible ISO", options: ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
            fx5.iso = Choice(800, options: [800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
                                            16000, 20000, 25600])
            fx5.baseISO = Choice(800, options: [800, 4000, 12800])
            fx5.baseSensitivity = nil
            // On MF: the push is live.
            fx5.focusMode = Choice("MF", options: ["AF", "MF"])
            fx5.focusIsAuto = false
            // False Color on a button, on.
            fx5.falseColor = Choice(true, options: [false, true])
            fx5.falseColorHint = nil
            // A dummy battery on external power: nothing the camera can read but where the power comes from.
            fx5.batteryPercent = nil
            fx5.batteryVolts = nil
            fx5.powerSource = "Ext"
            fx5.alerts = []
            let lutOn = Choice(true, options: [false, true])
            fx5.monitoring = MonitoringState(outputs: [MonitorOutput(id: "LUT1", name: "HDMI", overlays: [.lut: lutOn]),
                                                       MonitorOutput(id: "LUT2", name: "Proxy/Live View", overlays: [.lut: lutOn]),
                                                       MonitorOutput(id: "LUT3", name: "LCD/VF", overlays: [.lut: lutOn])])
            fx5.look = fx5.monitoring?.onEverywhere(.lut)
            let fx5Flexible = DashboardStore.galleryController(body: .fx6, label: "F", color: .orange,
                                                               backend: GalleryNullBackend(), state: fx5)
            // With a lens it can focus, so the gallery draws the Autofocus tile live.
            var pyxisWithAF = pyxisState()
            pyxisWithAF.canAutoFocus = true
            let pyxis = DashboardStore.galleryController(body: .fx3, label: "A", color: .red, backend: GalleryNullBackend(),
                                                         state: pyxisWithAF)
            let burano = DashboardStore.galleryController(body: .burano, label: "D", color: .green, backend: GalleryNullBackend())
            let venice = DashboardStore.galleryController(body: .venice2, label: "E", color: .purple, backend: GalleryNullBackend())
            LiveViewTilePreview.jpeg = galleryLiveFrame()
            let galleryView = GalleryView(fx3: fx3, fx6: fx6, fx6Custom: fx6Custom, fx5Custom: fx5Custom,
                                          fx5Flexible: fx5Flexible, pyxis: pyxis, burano: burano,
                                          venice: venice)
                .frame(width: GalleryView.canvasSize.width, height: GalleryView.canvasSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.alignmentAudit, audit)
            png = renderInWindow(galleryView, width: GalleryView.canvasSize.width, height: GalleryView.canvasSize.height)
        } else if mode == "edit" || mode == "window" {
            // The dashboard through a real window: needed for customized pages (ScrollView) and edit mode.
            // CC_SNAPSHOT_LOCKED=1: the controls locked (controls gray; read-outs and the Lock tile don't).
            // Both go in this process's argument domain, as the app's launch arguments do. Written to the persistent
            // domain, which every dashboard-snapshot shares, renders run side by side (the UI atlas, six at once) took
            // each other's: in the same process renders ran side by side and the locked renders were byte
            // for byte the unlocked ones.
            var flags = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            flags["CCDebugEditing"] = mode == "edit"
            flags["CCDebugLocked"] = ProcessInfo.processInfo.environment["CC_SNAPSHOT_LOCKED"] != nil
            UserDefaults.standard.setVolatileDomain(flags, forName: UserDefaults.argumentDomain)
            // A window that isn't the app's scene: say it's active, or live view (which only streams then) never starts.
            png = renderInWindow(DashboardView(store: store).environment(\.colorScheme, .dark).environment(\.alignmentAudit, audit)
                                    .environment(\.scenePhase, .active),
                                 width: width, height: height)
        } else if let screen {
            png = renderInWindow(DebugScreenView(store: store, screen: screen), width: width, height: height)
        } else {
            let renderer = ImageRenderer(content: DashboardView(store: store)
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark))
            // CC_SNAPSHOT_SCALE=2 for a Retina-sharp render when checking alignment.
            renderer.scale = Double(ProcessInfo.processInfo.environment["CC_SNAPSHOT_SCALE"] ?? "") ?? 1
            png = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        guard let png else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        try png.write(to: output)
        print("wrote \(output.path)")
        if ProcessInfo.processInfo.environment["CC_SNAPSHOT_BLACKMAGIC_LIVE"] != nil { endLiveViewStreams(store) }
        if audit != nil {
            let findings = AlignmentAudit.report()
            for line in findings { print("ALIGNMENT: \(line)") }
            if !findings.isEmpty { exit(2) }
            print("alignment: every tile lines up")
        }
    }



    /// Demo cameras of the bodies named (`CC_SNAPSHOT_BODIES`), A, B, C… on one automatic page.
    @MainActor
    static func bodiesStore(_ names: String) -> DashboardStore {
        let labels = ["A", "B", "C", "D"]
        let colors: [SlotColor] = [.red, .blue, .yellow, .green]
        let bodies = names.split(separator: ",").compactMap { name in MockBody.allCases.first { "\($0)" == name } }
        let cameras = bodies.prefix(4).enumerated().map { index, body in
            SavedCamera(slot: CameraSlot(label: labels[index], color: colors[index], host: "192.0.2.\(21 + index)"),
                        demoBody: body)
        }
        let page = CameraPage(name: cameras.map(\.slot.label).joined(separator: "+"), cameraIDs: cameras.map(\.slot.id))
        // CC_SNAPSHOT_RECORDING=A,B: those cameras rolling, a minute and a half into a take. CC_SNAPSHOT_OFFLINE=B: that one
        // not connected, with what it last reported.
        let rolling = ProcessInfo.processInfo.environment["CC_SNAPSHOT_RECORDING"]?.split(separator: ",").map(String.init) ?? []
        let offline = ProcessInfo.processInfo.environment["CC_SNAPSHOT_OFFLINE"]?.split(separator: ",").map(String.init) ?? []
        var states: [UUID: CameraState] = [:]
        for camera in cameras {
            var state = MockCameraBackend.sampleState(body: camera.demoBody ?? .fx3, label: camera.slot.label)
            if rolling.contains(camera.slot.label) {
                state.recording = RecordingControl(state: .recording)
                state.takeStartedAt = Date().addingTimeInterval(-94)
            }
            if offline.contains(camera.slot.label) {
                // As CameraController leaves it: no latency without a link.
                state.connection = .failed("The camera didn't answer.")
                state.latencyMilliseconds = nil
            }
            states[camera.slot.id] = state
        }
        return DashboardStore(cameras: cameras, pages: [page], currentPageID: page.id, startCameras: false,
                              initialStates: states)
    }

    /// Page "A": one Blackmagic camera, in the state the backend read from it (15 s to connect).
    @MainActor
    static func blackmagicStore(host: String) -> DashboardStore? {
        let tls = BlackmagicTLSDelegate()
        let backend = BlackmagicCameraBackend(host: host, useHTTPS: true,
                                              tlsSession: URLSession(configuration: .ephemeral, delegate: tls, delegateQueue: nil),
                                              delegate: tls)
        let read = ReadState()
        Task {
            Task { await backend.connect() }
            for await state in backend.updates where state.connection == .connected { read.state = state }
        }
        let deadline = Date().addingTimeInterval(15)
        while read.state == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // What comes right after connect too: every output's overlays, the latency.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let state = read.state else { return nil }
        let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: host),
                                 connection: .blackmagic(BlackmagicConnection(host: host, useHTTPS: true)))
        let page = CameraPage(id: UUID(), name: "A", cameraIDs: [camera.slot.id], showsAllCameras: false)
        return DashboardStore(cameras: [camera], pages: [page], currentPageID: page.id, startCameras: false,
                              initialStates: [camera.slot.id: state])
    }

    @MainActor final class ReadState { var state: CameraState? }

    /// The app's store with one Blackmagic camera, connecting as the app does (20 s to connect).
    @MainActor
    static func connectedBlackmagicStore(host: String, streamTo: String?) -> DashboardStore? {
        // CC_SNAPSHOT_BM_REMOTE=<remote password>: through Remote Control. The host may be usb:<serial>.
        let remote = ProcessInfo.processInfo.environment["CC_SNAPSHOT_BM_REMOTE"]
        let connection = BlackmagicConnection(host: host, useHTTPS: true, remoteControl: remote != nil)
        let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: host), connection: .blackmagic(connection))
        let page = CameraPage(id: UUID(), name: "A", cameraIDs: [camera.slot.id], showsAllCameras: false)
        let store = DashboardStore(cameras: [camera], pages: [page], currentPageID: page.id, startCameras: true) { saved, _ in
            // The app's own way of making it.
            let backend = BlackmagicCameraBackend.make(connection, password: remote)
            if let streamTo { Task { await backend.setLiveViewStreamAddress(streamTo) } }
            return backend
        }
        let deadline = Date().addingTimeInterval(20)
        while store.cameras.first.map({ !($0.state.connection == .connected && $0.state.hasLiveView) }) ?? true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return store.cameras.first?.state.connection == .connected ? store : nil
    }

    /// Ends each Blackmagic camera's live view stream now, not after the linger: the tool exits next.
    @MainActor
    static func endLiveViewStreams(_ store: DashboardStore) {
        let done = ReadState()
        Task {
            for camera in store.cameras {
                if let backend = camera.liveViewProvider as? BlackmagicCameraBackend { await backend.endLiveViewStream() }
            }
            done.state = CameraState()
        }
        let deadline = Date().addingTimeInterval(30)
        while done.state == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        print(ActivityLog.shared.text)
    }

    /// Page "A": a PYXIS 12K in the state the backend read from one (off-speed and some overlays turned on). With
    /// CC_SNAPSHOT_REMOTE_CONTROL=1 it's saved through the camera's Remote Control (its editor shows that way in).
    @MainActor
    static func pyxisStore() -> DashboardStore {
        let remote = ProcessInfo.processInfo.environment["CC_SNAPSHOT_REMOTE_CONTROL"] != nil
        let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "pyxis-12k"),
                                 connection: .blackmagic(BlackmagicConnection(host: "pyxis-12k", useHTTPS: true,
                                                                              remoteControl: remote)))
        let page = CameraPage(id: UUID(), name: "A", cameraIDs: [camera.slot.id], showsAllCameras: false)
        return DashboardStore(cameras: [camera], pages: [page], currentPageID: page.id, startCameras: false,
                              initialStates: [camera.slot.id: pyxisState()])
    }

    /// Page "A": a PYXIS 12K that isn't connected, saved with what it reported last time (its tiles and outputs).
    @MainActor
    static func pyxisOfflineStore() -> DashboardStore {
        var camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "pyxis-12k"),
                                 connection: .blackmagic(BlackmagicConnection(host: "pyxis-12k", useHTTPS: true)))
        let state = pyxisState()
        camera.lastSeen = CameraProfile(model: state.model, offered: Set(WidgetKind.allCases.filter { state.offers($0) }),
                                        make: .blackmagic, outputs: state.monitoring?.outputs.map(TileOutput.init))
        let page = CameraPage(id: UUID(), name: "A", cameraIDs: [camera.slot.id], showsAllCameras: false)
        return DashboardStore(cameras: [camera], pages: [page], currentPageID: page.id, startCameras: false)
    }

    /// The PYXIS 12K as the backend reads it, off-speed and overlays on (`MockCameraBackend.pyxisSampleState`).
    static func pyxisState() -> CameraState { MockCameraBackend.pyxisSampleState() }

    @MainActor
    static func renderInWindow(_ view: some View, width: Double, height: Double) -> Data? {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        // Let SwiftUI lay out and AppKit controls draw before capturing (CC_SNAPSHOT_WAIT=<s>: longer, for live view).
        RunLoop.main.run(until: Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["CC_SNAPSHOT_WAIT"] ?? "") ?? 0.8))
        // CC_SNAPSHOT_SCALE=2 draws at Retina density (a headless Mac's window backing is 1x).
        let scale = Double(ProcessInfo.processInfo.environment["CC_SNAPSHOT_SCALE"] ?? "") ?? 1
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A stand-in live view frame for the gallery: a 3:2 test card (gradient, grid, a subject), JPEG like the camera's.
func galleryLiveFrame() -> Data? {
    let w = 640, h = 426
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let colors = [CGColor(red: 0.10, green: 0.18, blue: 0.30, alpha: 1), CGColor(red: 0.85, green: 0.55, blue: 0.30, alpha: 1)] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.25)); ctx.setLineWidth(1)
    for i in 1..<3 {  // rule of thirds
        ctx.move(to: CGPoint(x: w * i / 3, y: 0)); ctx.addLine(to: CGPoint(x: w * i / 3, y: h))
        ctx.move(to: CGPoint(x: 0, y: h * i / 3)); ctx.addLine(to: CGPoint(x: w, y: h * i / 3))
    }
    ctx.strokePath()
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: w * 2 / 3 - 60, y: h / 3 - 20, width: 120, height: 150))
    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}
