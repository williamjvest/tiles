import ArriWebRemote
import BlackmagicRESTBackend
import BlackmagicBLE
import CameraCore
import DashboardUI
import SonyPTP
import SonySavona
import SwiftUI

@main
struct CameraControlApp: App {
    /// Saved cameras and pages. Camera passwords live in the Keychain.
    @State private var store: DashboardStore = {
        if UserDefaults.standard.bool(forKey: "CCDebugOfflinePYXIS") { return CameraControlApp.offlinePYXISStore() }
        // Screenshots and UI checks (`-CCDebugDemoLineup YES`): the four demo cameras and their pages (All, A+B, C), as
        // the snapshot tool draws them, held in memory: the app's real setup is untouched.
        if UserDefaults.standard.bool(forKey: "CCDebugDemoLineup") { return DashboardStore.preview() }
        // `-CCDebugDemoBodies venice2,venice2`: working demos of those bodies on one page, held in memory too.
        if let bodies = UserDefaults.standard.string(forKey: "CCDebugDemoBodies") { return DashboardStore.demoBodies(bodies) }
        // Cameras other than demos wait for the Terms of Use: agreed once, before any connects (TermsOfUse).
        let store = DashboardStore.load(holdsRealCameras: !TermsOfUse.isAccepted(in: .standard),
                                        credentials: KeychainCredentialStore(), makeBackend: CameraControlApp.makeBackend)
        CameraControlApp.importInstallerSeed(into: store)
        return store
    }()

    /// Screenshots and UI checks (launch argument `-CCDebugOfflinePYXIS YES`): a PYXIS 12K that isn't connected, saved
    /// with what one reports (so its page is the one a real camera gets, not every tile there is), on a page of its own,
    /// in Test Mode, so that page can be checked on any device without the camera. Nothing is saved and nothing connects
    /// (a documentation address, RFC 5737): the app's real setup is untouched.
    @MainActor
    static func offlinePYXISStore() -> DashboardStore {
        let sample = MockCameraBackend.pyxisSampleState()
        var camera = SavedCamera(slot: CameraSlot(label: "P", color: .red, host: "192.0.2.10"),
                                 connection: .blackmagic(BlackmagicConnection(host: "192.0.2.10")))
        camera.lastSeen = CameraProfile(model: sample.model, offered: Set(WidgetKind.allCases.filter { sample.offers($0) }),
                                        make: .blackmagic, outputs: sample.monitoring?.outputs.map(TileOutput.init))
        let page = CameraPage(name: "P", cameraIDs: [camera.slot.id])
        let store = DashboardStore(cameras: [camera], pages: [page], currentPageID: page.id, startCameras: false,
                                   makeBackend: makeBackend)
        store.testMode = true
        return store
    }

    /// Settings → Appearance, read before the first frame so a custom look never opens on a frame of the standard one.
    /// Screenshots and UI checks run on a setup held in memory, and draw the standard look too whatever the device has
    /// saved; `-CCDebugAppearance custom` gives them custom colors, `-CCDebugTextSize dynamic` Dynamic Text Size, and
    /// `-CCDebugTextScale 1.5` Text Size's slider, unsaved.
    init() {
        let defaults = UserDefaults.standard
        let heldInMemory = defaults.bool(forKey: "CCDebugOfflinePYXIS") || defaults.bool(forKey: "CCDebugDemoLineup")
            || defaults.string(forKey: "CCDebugDemoBodies") != nil
        if !heldInMemory {
            ThemeStore.shared.load(from: defaults)
        } else {
            if defaults.string(forKey: "CCDebugAppearance") == "custom" { ThemeStore.shared.appearance.customColors = true }
            if defaults.string(forKey: "CCDebugTextSize") == "dynamic" { ThemeStore.shared.appearance.textSize = .dynamic }
            if let scale = defaults.string(forKey: "CCDebugTextScale").flatMap(Double.init) {
                ThemeStore.shared.appearance.textScale = scale
            }
        }
    }

    private let controlTokenStore = ControlServerTokenStore()
    @State private var controlServer: ControlServer?

    /// Real cameras the installer copied into Documents/tw-cc-seed.json over USB (never in the app bundle or
    /// the repo). Imported once at launch, then deleted, so the password only lives in the Keychain.
    @MainActor
    static func importInstallerSeed(into store: DashboardStore) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("tw-cc-seed.json")
        guard let data = try? Data(contentsOf: url) else { return }
        store.importSeed(data)
        try? FileManager.default.removeItem(at: url)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store,
                          controlServer: controlServer,
                          controlTokenStore: controlTokenStore)
                #if os(macOS)
                .frame(minWidth: 1100, minHeight: 760)
                #elseif os(iOS)
                .modifier(KeepScreenOn(store: store))
                #endif
                .modifier(AgeAssurance(store: store))
                .task {
                    // Create the control server once the store is available.
                    let server = ControlServer(tokenStore: controlTokenStore, store: store)
                    controlServer = server
                    if store.controlAPIEnabled { try? server.start() }  // fixed ports 51800/51801
                }
        }
        .commands { DashboardCommands() }
        #if os(iOS)
        // iOS suspends a backgrounded app and its sockets die. Close cleanly on the way out and reconnect
        // on return, rather than finding out from a timeout. (A Mac app keeps running in the background.)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.suspendAll()
                controlServer?.stop()    // iOS: server only runs in foreground
            case .active:
                store.resumeAll()
                if store.controlAPIEnabled { try? controlServer?.start() }
            default:
                break
            }
        }
        #endif
        #if os(macOS)
        WindowGroup("Live View", id: LiveViewWindow.id, for: UUID.self) { $cameraID in
            if let id = cameraID, let camera = store.camera(id) { LiveViewWindow(camera: camera) }
        }
        #endif
    }

    #if os(iOS)
    /// A locked iPhone or iPad suspends Tiles and drops every camera, so the screen stays on while one is in use.
    private struct KeepScreenOn: ViewModifier {
        let store: DashboardStore
        func body(content: Content) -> some View {
            content.onChange(of: store.isUsingACamera, initial: true) { _, inUse in
                UIApplication.shared.isIdleTimerDisabled = inUse
            }
        }
    }
    #endif

    /// Build the correct backend for a saved camera.
    /// - Demo cameras get `MockCameraBackend`.
    /// - Sony cameras get `SonyCameraBackend`, with SSH when Access Authentication is enabled.
    /// - Blackmagic cameras get `BlackmagicCameraBackend`, with a pinned TLS session when HTTPS is enabled.
    @MainActor
    static func makeBackend(_ camera: SavedCamera, password: String?) -> any CameraBackend {
        switch camera.connection {
        case .demo(let body):
            return MockCameraBackend(body: body, label: camera.slot.label)
        case .sony(let conn):
            let store = KeychainInitiatorIdentityStore()
            return SonyCameraBackend(
                host: camera.slot.host,
                identityStore: store,
                sshUsername: conn.usesAccessAuthentication ? conn.username : nil,
                password: password,
                trustedFingerprint: conn.trustedFingerprint
            )
        case .blackmagic(let conn):
            // The password is with the camera's other secrets.
            return BlackmagicCameraBackend.make(conn, password: password, knownLUTs: camera.lastSeen?.luts ?? [])
        case .blackmagicBluetooth(let conn):
            return BlackmagicBluetoothBackend(link: CoreBluetoothLink(peripheralID: conn.peripheralID))
        case .venice(let conn):
            return VeniceCameraBackend(host: camera.slot.host, user: conn.username, password: password,
                                       label: camera.slot.label)
        case .arri:
            return ArriCameraBackend(host: camera.slot.host, label: camera.slot.label)
        }
    }
}
