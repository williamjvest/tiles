import SwiftUI
import CameraCore

/// Opens a settings screen directly, for screenshots and UI checks: launch with `-CCDebugScreen settings`,
/// or render it with `dashboard-snapshot`.
public enum DebugScreen: String, Identifiable, CaseIterable, Sendable {
    case settings
    case cameraEditor = "camera-editor"
    case addCamera = "add-camera"
    case pageEditor = "page-editor"
    case controlAPI = "control-api"
    case liveView = "live-view"
    case addTile = "add-tile"
    case profileList = "profile-list"
    case profileEditor = "profile-editor"
    case clipNaming = "clip-naming"
    case monitoring
    case haLowNodes = "halow-nodes"
    case appearance
    /// Tiles' color picker on its own (`ColourPickerPanel`), as a popover shows it.
    case colourPicker = "colour-picker"
    /// The Terms of Use sheet, as a new install sees it.
    case terms
    /// Settings → About Tiles.
    case about
    /// Settings → Report a Problem.
    case report
    /// The first camera's own buttons that lists any (`CameraMenuView`).
    case cameraMenu = "camera-menu"
    /// A Blackmagic camera's audio channels (`AudioView`): a demo PYXIS's where no camera here has any.
    case audio
    /// The Clips window (`ClipListView`): the first camera here that lists clips, else a demo PYXIS playing its third.
    case clips

    public var id: String { rawValue }
}

public struct DebugScreenView: View {
    let store: DashboardStore
    let screen: DebugScreen
    @Environment(\.dismiss) private var dismiss

    public init(store: DashboardStore, screen: DebugScreen) {
        self.store = store
        self.screen = screen
    }

    public var body: some View {
        switch screen {
        case .settings:
            SettingsSheet(store: store)
        case .cameraEditor:
            CameraEditor(store: store, target: store.cameras.first.map { .existing($0.id) } ?? .new)
        case .addCamera:
            CameraEditor(store: store, target: .new)
        case .pageEditor:
            PageEditor(store: store, target: store.currentPage.map { .existing($0.id) } ?? .new)
        case .controlAPI:
            ControlAPIDebugScreen(store: store)
        case .addTile:
            if let page = store.currentPage {
                AddTileSheet(store: store, pageID: page.id, phoneCameraID: nil)
            }
        case .liveView:
            // The sheet over the first camera that can stream (a preview store's demo cameras aren't connected, so
            // it shows its not-available state; enough to check the layout and the Done button).
            if let camera = store.cameras.first(where: { $0.liveViewProvider != nil }) {
                LiveViewSheet(camera: camera)
            }
        case .profileList:
            NavigationStack { ProfileListView(store: store) }
        case .profileEditor:
            ProfileEditor(store: store, target: .new)
        case .clipNaming:
            if let camera = store.visibleCameras.first(where: { $0.state.fileNaming != nil }) {
                ClipNamingView(camera: camera)
            }
        case .monitoring:
            if let camera = store.visibleCameras.first(where: { $0.state.monitoring != nil }) {
                MonitoringView(camera: camera)
            }
        case .haLowNodes:
            NavigationStack {
                Form { HaLowSettingsSection(store: store) }
                    .formStyle(.grouped)
                    .navigationTitle("HaLow Nodes")
            }
        case .appearance:
            NavigationStack { AppearanceView() }
                .preferredColorScheme(.dark)
        case .colourPicker:
            ColourPickerPreview()
        case .terms:
            // Agree closes it: the sheet itself can't be swiped away.
            TermsSheet { dismiss() }
        case .about:
            NavigationStack { AboutView(store: store) }
                .preferredColorScheme(.dark)
        case .report:
            NavigationStack { ProblemReportView(store: store) }
                .preferredColorScheme(.dark)
        case .cameraMenu:
            if let camera = store.visibleCameras.first(where: { !$0.state.cameraButtons.isEmpty }) {
                CameraMenuView(camera: camera)
            }
        case .audio:
            AudioDebugScreen(camera: store.visibleCameras.first { !$0.state.audioChannels.isEmpty })
        case .clips:
            ClipsDebugScreen(camera: store.visibleCameras.first { $0.state.playback?.clipListing != nil })
        }
    }
}

/// The Clips window for a camera that lists clips, else for a demo PYXIS in review, playing its third of 48.
private struct ClipsDebugScreen: View {
    let camera: CameraController?
    @State private var sample: CameraController = {
        var state = MockCameraBackend.pyxisSampleState()
        state.playback?.inReview = true
        state.playback?.isPlaying = true
        state.playback?.clipNumber = 3
        return DashboardStore.galleryController(body: .pyxis12K, label: "A", color: .red,
                                                backend: MockCameraBackend(state: state), state: state)
    }()

    var body: some View { ClipListView(camera: camera ?? sample) }
}

/// The Audio window for a camera that has audio channels, else for a demo PYXIS (`pyxisSampleState`) that goes nowhere.
private struct AudioDebugScreen: View {
    let camera: CameraController?
    @State private var sample = DashboardStore.galleryController(
        body: .fx3, label: "A", color: .red, backend: MockCameraBackend(state: MockCameraBackend.pyxisSampleState()),
        state: MockCameraBackend.pyxisSampleState())

    var body: some View { AudioView(camera: camera ?? sample) }
}

/// Which camera or page an editor sheet is for.
enum EditorTarget: Identifiable, Hashable {
    case new
    case existing(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let id): id.uuidString
        }
    }

    var isNew: Bool { self == .new }
}

/// Settings (the gear button): the cameras and pages, then everything else.
struct SettingsSheet: View {
    let store: DashboardStore
    /// Optional control server; when provided, a Control API row appears in settings.
    var controlServer: ControlServer?
    var tokenStore: ControlServerTokenStore?
    @Environment(\.dismiss) private var dismiss
    @State private var cameraTarget: EditorTarget?
    @State private var pageTarget: EditorTarget?

    private var haLowSummary: String {
        let count = store.haLowNodes.count
        if store.haLowSettings.displayMode == .off { return "Off" }
        if count == 0 { return store.hasHaLowPassword ? "None found" : "Not set up" }
        return count == 1 ? "1 node" : "\(count) nodes"
    }

    var body: some View {
        NavigationStack {
            // Six groups, and a line of footer only under a switch: a row that opens a screen explains itself there.
            Form {
                Section {
                    ForEach(store.cameras) { camera in
                        Button { cameraTarget = .existing(camera.id) } label: {
                            HStack(spacing: 12) {
                                // A label can be more than a letter ("FX3"): one line, as wide as it needs.
                                Text(camera.slot.label)
                                    .font(Theme.mono(18, weight: .heavy))
                                    .foregroundStyle(camera.slot.tint)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(minWidth: 30, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(camera.slot.host.isEmpty ? "No address" : USBCameraAddress.display(camera.slot.host))
                                        .font(.body.monospaced())
                                        .foregroundStyle(Theme.sheet.text)
                                    Text(connectionSummary(store.savedCamera(camera.id)?.connection))
                                        .font(.caption)
                                        .foregroundStyle(Theme.sheet.secondaryText)
                                }
                                Spacer()
                                Circle()
                                    .fill(camera.state.connection == .connected ? Theme.sheet.timecode : Theme.sheet.secondaryText)
                                    .frame(width: 8, height: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { store.moveCameras(fromOffsets: $0, toOffset: $1) }
                    Button { cameraTarget = .new } label: {
                        Label("Add Camera", systemImage: "plus")
                    }
                    NavigationLink { ProfileListView(store: store) } label: {
                        row("Camera Profiles", value: store.profiles.isEmpty ? nil : "\(store.profiles.count)")
                    }
                } header: {
                    Text("Cameras")
                }

                Section {
                    ForEach(store.pages) { page in
                        Button { pageTarget = .existing(page.id) } label: {
                            HStack {
                                Text(page.name).foregroundStyle(Theme.sheet.text)
                                Spacer()
                                Text(page.showsAllCameras ? "All cameras" : "\(page.cameraIDs.count) camera\(page.cameraIDs.count == 1 ? "" : "s")")
                                    .foregroundStyle(Theme.sheet.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { store.movePages(fromOffsets: $0, toOffset: $1) }
                    Button { pageTarget = .new } label: {
                        Label("Add Page", systemImage: "plus")
                    }
                } header: {
                    Text("Pages")
                }

                Section {
                    NavigationLink { AppearanceView() } label: {
                        row("Appearance", value: appearanceSummary(ThemeStore.shared.appearance))
                    }
                    Toggle("Test Mode", isOn: Binding(get: { store.testMode }, set: { store.testMode = $0 }))
                } footer: {
                    FooterText("Test Mode runs a camera that isn't connected as a demo of itself, so its pages can be tried with it off.")
                }

                Section {
                    NavigationLink { LUTNamesView(store: store) } label: {
                        row("LUT Names", value: store.lutNames.isEmpty ? nil : "\(store.lutNames.count) renamed")
                    }
                    Toggle("Add False Color to FX3s", isOn: Binding(
                        get: { store.addsFalseColorLUT }, set: { store.addsFalseColorLUT = $0 }))
                } header: {
                    Text("LUTs")
                } footer: {
                    FooterText("An FX3 without a false color LUT gets Tiles' in its first empty User slot. A LUT already there is never replaced.")
                }

                Section {
                    // Its own page: most setups have no HaLow nodes, and opening it is what looks for them.
                    NavigationLink {
                        Form {
                            HaLowSettingsSection(store: store)
                        }
                        .formStyle(.grouped)
                        .navigationTitle("HaLow Nodes")
                    } label: {
                        row("HaLow Nodes", value: haLowSummary)
                    }
                    if let server = controlServer, let ts = tokenStore {
                        NavigationLink {
                            ControlAPISettingsView(store: store, server: server, tokenStore: ts)
                        } label: {
                            row("Control API", value: server.isRunning ? "On" : "Off")
                        }
                    }
                } header: {
                    Text("Connections")
                }

                Section {
                    NavigationLink("Report a Problem") {
                        ProblemReportView(store: store, controlAPIOn: controlServer?.isRunning == true)
                    }
                    .accessibilityIdentifier("settings.reportProblem")
                    NavigationLink { AboutView(store: store) } label: {
                        row("About Tiles", value: AboutView.version)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $cameraTarget) { CameraEditor(store: store, target: $0) }
            .sheet(item: $pageTarget) { PageEditor(store: store, target: $0) }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 540, idealHeight: 640)
        #endif
    }
}

extension SettingsSheet {
    /// A row that opens a screen: its name, and on the right what it's set to, as iOS Settings shows one.
    func row(_ title: String, value: String?) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.sheet.text)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(Theme.sheet.secondaryText)
            }
        }
    }
}

func copyToPasteboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// A camera's user name and password, the same in every editor. On iPhone and iPad a form field shows its prompt, not
/// its title, so the prompts say what goes in and the note under them says where it's set: two fields both reading
/// "as shown on the camera" would say nothing.
struct CredentialFields: View {
    /// Nil for a password alone (a Blackmagic camera's Remote Control).
    var username: Binding<String>?
    @Binding var password: String
    var passwordTitle = "Password"
    var note: String

    static let sony = "The user name and password set on the camera, under Access Authentication in its Network menu."
    static let venice = "The VENICE's user name is admin unless it's been changed; its password is under "
        + "Technical > Authentication."
    static let blackmagic = "The user name and password set for the camera in Blackmagic Camera Setup."
    static let blackmagicRemote = "The remote control password set on the camera."

    var body: some View {
        if let username {
            TextField("User Name", text: username, prompt: Text("User Name"))
                .modifier(HostFieldStyle())
        }
        PasswordField(title: passwordTitle, text: $password, prompt: Text(passwordTitle))
        Text(note)
            .font(.footnote)
            .foregroundStyle(Theme.sheet.secondaryText)
    }
}

/// Footer text that wraps instead of running off the edge (macOS form footers don't wrap by default).
struct FooterText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.sheet.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum CameraType: CaseIterable, Equatable {
    case sony, blackmagic, arri, demo
    var label: String {
        switch self {
        // Short: four segments share a phone-width row (the picker hides its "Type" label to give them the room).
        case .sony: "Sony"
        case .blackmagic: "Blackmagic"
        case .arri: "ARRI"
        case .demo: "Demo"
        }
    }

    init(_ profile: ProfileCameraType) {
        switch profile {
        case .sony: self = .sony
        case .blackmagic: self = .blackmagic
        case .arri: self = .arri
        }
    }
}

struct CameraEditor: View {
    let store: DashboardStore
    let target: EditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var confirmingRemove = false
    @State private var color: SlotColor = .red
    /// A color picked instead of one of the eight (`CameraSlot.customColor`).
    @State private var customColor: AppearanceSettings.RGB?
    @State private var host = ""
    @State private var cameraType: CameraType = .sony
    @State private var demoBody: MockBody = .fx3
    @State private var accessAuthentication = true
    /// Sony: the PTP Camera Remote protocol (FX3/FX6/BURANO), or the VENICE Web Remote.
    @State private var sonyWebRemote = false
    /// What asking the camera found (`SonyRemoteProbe`), and whether the user has picked the protocol themselves, in
    /// which case it's left alone.
    @State private var probedProtocol: SonyRemoteProbe.Result?
    /// What asking an ARRI address found (`ArriRemoteProbe`).
    @State private var probedArri: ArriRemoteProbe.Result?
    @State private var probedBlackmagic: BlackmagicAccessProbe.Result?
    @State private var probing = false
    @State private var protocolPickedByHand = false
    /// A Blackmagic camera's way in was picked here (or saved, or from a profile): what the address answers doesn't change
    /// it.
    @State private var bmAccessPickedByHand = false
    /// A Blackmagic camera's login (most have none).
    @State private var bmLogin = false
    @State private var username = ""
    @State private var password = ""
    @State private var fingerprint: String?
    @State private var bmUseHTTPS = false
    @State private var bmFingerprint: String?
    /// Through the camera's Remote Control, with only its remote password, rather than its Network Access.
    @State private var bmRemoteControl = false
    /// A Bluetooth camera's name as it advertised itself (its address is `bt:<identifier>`).
    @State private var bluetoothName = ""
    @State private var loaded = false
    @State private var showLUTImport = false
    @State private var showSaveAsProfile = false

    var body: some View {
        NavigationStack {
            Form {
                if target.isNew && !store.profiles.isEmpty {
                    ProfilesSection(
                        profiles: store.profiles,
                        existingHosts: Set(store.cameras.map(\.slot.host)),
                        selectedHost: host,
                        onSelect: { profile in
                            host = profile.address
                            cameraType = CameraType(profile.cameraType)
                            color = profile.color
                            customColor = profile.customColor
                            accessAuthentication = profile.useAccessAuthentication
                            bmLogin = profile.cameraType == .blackmagic && profile.useAccessAuthentication
                            username = profile.username ?? ""
                            bmUseHTTPS = profile.useHTTPS
                            bmRemoteControl = profile.cameraType == .blackmagic && profile.remoteControl == true
                            bmAccessPickedByHand = profile.cameraType == .blackmagic
                            if let suggested = profile.suggestedLetter(usedLabels: Set(store.cameras.map(\.slot.label))) {
                                label = suggested
                            }
                            // Always replace it: tapping one profile after another mustn't keep the first one's password.
                            password = store.credentials.profilePassword(for: profile.id) ?? ""
                        }
                    )
                }
                #if os(macOS) || canImport(ImageCaptureCore)
                if target.isNew {
                    USBCamerasSection(existingHosts: Set(store.cameras.map(\.slot.host)), selectedHost: host) { usbHost, type in
                        host = usbHost
                        cameraType = type
                        accessAuthentication = false
                        if type == .blackmagic {
                            bmLogin = false
                            bmAccessPickedByHand = false  // the camera is asked which way in it has
                        }
                    }
                }
                #endif
                #if canImport(CoreBluetooth)
                if target.isNew {
                    BluetoothCamerasSection(existingHosts: Set(store.cameras.map(\.slot.host)), selectedHost: host) { id, name in
                        host = BluetoothCameraAddress.host(id: id)
                        bluetoothName = name
                        cameraType = .blackmagic
                    }
                }
                #endif
                if target.isNew {
                    NetworkCamerasSection(
                        existingHosts: Set(store.cameras.map(\.slot.host)), selectedHost: host,
                        meshHosts: store.offersMeshDevices ? { await store.scanMesh().devices.map(\.ip) } : nil
                    ) { camera in
                        host = camera.host
                        cameraType = CameraType(camera.maker)
                        switch camera.maker {
                        case .sony:
                            accessAuthentication = camera.needsLogin
                        case .blackmagic:
                            bmLogin = false
                            bmAccessPickedByHand = false  // the camera is asked which way in it has
                        case .arri:
                            break
                        }
                    }
                }
                if target.isNew && store.offersMeshDevices {
                    MeshDevicesSection(
                        initial: store.meshPreview,
                        scan: { await store.scanMesh() },
                        existingHosts: Set(store.cameras.map(\.slot.host)),
                        selectedHost: host,
                        onSelect: { device in
                            host = device.ip
                            if let maker = device.cameraMaker { cameraType = CameraType(maker) }
                        }
                    )
                }
                Section("Camera") {
                    TextField("Label", text: $label, prompt: Text("A"))
                    LabeledContent("Color") {
                        ColorChooser(selection: $color, custom: $customColor)
                    }
                    if let serial = usbSerial {
                        LabeledContent("Address") {
                            HStack(spacing: 8) {
                                Text(verbatim: "USB · \(USBCameraAddress.label(serial: serial))").font(.body.monospaced())
                                Button("Change") { host = "" }
                            }
                        }
                    } else if isBluetooth {
                        LabeledContent("Address") {
                            HStack(spacing: 8) {
                                Text(verbatim: "Bluetooth · \(bluetoothName)")
                                Button("Change") { host = ""; bluetoothName = "" }
                            }
                        }
                    } else if cameraType != .demo {
                        TextField("Address", text: $host, prompt: Text(hostPrompt))
                            .modifier(HostFieldStyle())
                    }
                }
                Section {
                    Picker("Type", selection: $cameraType) {
                        ForEach(CameraType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch cameraType {
                    case .demo:
                        Picker("Pretend to be", selection: $demoBody) {
                            ForEach(MockBody.allCases, id: \.self) { body in
                                Text(body.displayName).tag(body)
                            }
                        }
                    case .sony where usbSerial != nil:
                        EmptyView()  // a cable needs no login
                    case .sony:
                        Picker("Camera", selection: Binding(get: { sonyWebRemote },
                                                            set: { sonyWebRemote = $0; protocolPickedByHand = true })) {
                            Text("FX3 · FX30 · FX5 · FX6 · BURANO").tag(false)
                            Text("VENICE · VENICE 2").tag(true)
                        }
                        if probing {
                            Text("Checking the camera…").font(.footnote).foregroundStyle(Theme.sheet.secondaryText)
                        } else if let probedProtocol {
                            Text(probedProtocol == .webRemote ? "This camera answered as a VENICE (its Web Remote)."
                                 : "This camera answered as an FX3, FX30, FX5, FX6 or BURANO (Camera Remote Control).")
                                .font(.footnote)
                                .foregroundStyle(Theme.sheet.secondaryText)
                        }
                        if sonyWebRemote {
                            // VENICE / VENICE 2, over the camera's own Web Remote protocol.
                            CredentialFields(username: $username, password: $password, note: CredentialFields.venice)
                        } else {
                        Toggle("Access Authentication", isOn: $accessAuthentication)
                        if accessAuthentication {
                            CredentialFields(username: $username, password: $password, note: CredentialFields.sony)
                            LabeledContent("Fingerprint") {
                                Text(fingerprint ?? "Saved on first connect")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(fingerprint == nil ? Theme.sheet.secondaryText : Theme.sheet.text)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            if fingerprint != nil {
                                Button("Forget Fingerprint", role: .destructive) { fingerprint = nil }
                            }
                        }
                        }
                    case .arri:
                        // ALEXA Mini, Mini LF, ALEXA 35, AMIRA: the Web Remote has no login.
                        if probing {
                            Text("Checking the camera…").font(.footnote).foregroundStyle(Theme.sheet.secondaryText)
                        } else if let probedArri {
                            Text(arriProbeText(probedArri)).font(.footnote).foregroundStyle(Theme.sheet.secondaryText)
                        }
                    case .blackmagic where isBluetooth:
                        EmptyView()  // Bluetooth bonds with the code the camera shows: no login, no certificate
                    case .blackmagic:
                        BlackmagicAccessPicker(remoteControl: Binding(get: { bmRemoteControl },
                                                                      set: { bmRemoteControl = $0; bmAccessPickedByHand = true }))
                        if probing {
                            Text("Checking the camera…").font(.footnote).foregroundStyle(Theme.sheet.secondaryText)
                        } else if let probedBlackmagic {
                            Text(blackmagicProbeText(probedBlackmagic)).font(.footnote).foregroundStyle(Theme.sheet.secondaryText)
                        }
                        if bmRemoteControl {
                            CredentialFields(username: nil, password: $password, passwordTitle: "Remote Password",
                                             note: CredentialFields.blackmagicRemote)
                        } else {
                            Toggle("Login", isOn: $bmLogin)
                            if bmLogin {
                                CredentialFields(username: $username, password: $password, note: CredentialFields.blackmagic)
                            }
                            Toggle("HTTPS", isOn: $bmUseHTTPS)
                        }
                        if bmRemoteControl || bmUseHTTPS {
                            LabeledContent("Certificate") {
                                Text(bmFingerprint == nil ? "Saved on first connect" : "Pinned")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(bmFingerprint == nil ? Theme.sheet.secondaryText : Theme.sheet.text)
                            }
                            if bmFingerprint != nil {
                                Button("Forget Certificate", role: .destructive) { bmFingerprint = nil }
                            }
                        }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    FooterText(connectionFooter)
                }
                if case .existing(let id) = target,
                   let controller = store.cameras.first(where: { $0.id == id }),
                   controller.lutImporter != nil {
                    Section {
                        Button {
                            showLUTImport = true
                        } label: {
                            Label("Load LUT onto Camera…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!controller.state.connection.isControllable)
                    } header: {
                        Text("LUT Files")
                    } footer: {
                        FooterText(
                            controller.state.connection.isControllable
                                ? "Import a .cube file into one of the camera's 16 User LUT slots."
                                : "Connect the camera to load a LUT."
                        )
                    }
                }
                if case .existing = target, cameraType != .demo {
                    Section {
                        Button("Save as Profile") {
                            showSaveAsProfile = true
                        }
                    } footer: {
                        FooterText("Creates a profile from this camera's settings for quick reuse in Add Camera.")
                    }
                }
                if case .existing(let id) = target {
                    Section {
                        // Asked first: it drops the camera's connection and its tiles from every page, with no undo.
                        Button("Remove Camera…", role: .destructive) { confirmingRemove = true }
                            .confirmationDialog("Remove camera \(label.isEmpty ? "" : label)?", isPresented: $confirmingRemove,
                                                titleVisibility: .visible) {
                                Button("Remove Camera", role: .destructive) {
                                    store.removeCamera(id)
                                    dismiss()
                                }
                            } message: {
                                Text("It disconnects, and its tiles come off every page.")
                            }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(target.isNew ? "Add Camera" : "Edit Camera")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.isNew ? "Add" : "Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .task(id: "\(host)|\(cameraType)") { await detectProtocol() }
            .sheet(isPresented: $showLUTImport) {
                if case .existing(let id) = target,
                   let controller = store.cameras.first(where: { $0.id == id }) {
                    LUTImportView(camera: controller)
                }
            }
            .sheet(isPresented: $showSaveAsProfile) {
                if case .existing(let id) = target {
                    SaveAsProfileSheet(store: store, cameraID: id)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 480)
        #endif
    }

    /// Ask the camera at the address which protocol it speaks, and pick it, unless the user already picked one. An
    /// ARRI address is asked whether it's a Web Remote, and says which camera.
    private func detectProtocol() async {
        probedProtocol = nil
        probedArri = nil
        probedBlackmagic = nil
        probing = false
        guard cameraType == .sony || cameraType == .arri || (cameraType == .blackmagic && !isBluetooth),
              usbSerial == nil || cameraType == .blackmagic,
              !host.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))  // typing: wait for the address to settle
        guard !Task.isCancelled else { return }
        probing = true
        if cameraType == .blackmagic {
            // On a cable: asked where the cable reaches it.
            var address: String? = host
            if let usbSerial { address = try? await BlackmagicUSBLink.address(serial: usbSerial, patience: .seconds(5)) }
            var found: BlackmagicAccessProbe.Result?
            if let address { found = await BlackmagicAccessProbe.probe(host: address) }
            guard !Task.isCancelled else { return }
            probing = false
            probedBlackmagic = found
            if let found, found != .neither, !bmAccessPickedByHand { bmRemoteControl = found == .remoteControl }
            return
        }
        if cameraType == .arri {
            let found = await ArriRemoteProbe.probe(host: host)
            guard !Task.isCancelled else { return }
            probing = false
            probedArri = found
            return
        }
        let found = await SonyRemoteProbe.probe(host: host)
        guard !Task.isCancelled else { return }
        probing = false
        probedProtocol = found
        if let found, !protocolPickedByHand { sonyWebRemote = found == .webRemote }
    }

    private func blackmagicProbeText(_ found: BlackmagicAccessProbe.Result) -> String {
        switch found {
        case .remoteControl: "This camera answered on Remote Control: only its remote password is needed."
        case .networkAccess:
            "This camera answered on Network Access. Turn on Remote Control on the camera (Setup, page 13) to use just a remote password instead."
        case .neither: "Neither Remote Control nor Network Access answered at this address."
        }
    }

    private func arriProbeText(_ found: ArriRemoteProbe.Result) -> String {
        switch found {
        case .arri(let model): "This camera answered as \(model.map { "an \($0)" } ?? "an ARRI camera") (its Web Remote)."
        case .notArri: "No ARRI Web Remote at this address."
        }
    }

    private var hostPrompt: String {
        switch cameraType {
        case .blackmagic: "IP address or pyxis-12k.local"
        case .arri: "IP address or mini-12345.local"
        default: "IP address"
        }
    }

    /// The camera's USB serial number, when it's on a cable rather than at an address.
    private var usbSerial: String? { USBCameraAddress.serial(in: host) }

    /// A Blackmagic camera on a cable: the start of its footer.
    private var blackmagicCable: String {
        usbSerial == nil ? "" : "On a USB-C cable, in any port: Tiles finds it there each time it connects. "
    }

    /// A Blackmagic camera picked from the Bluetooth list rather than typed in.
    private var isBluetooth: Bool { cameraType == .blackmagic && BluetoothCameraAddress.id(in: host) != nil }

    private var canSave: Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if cameraType == .demo { return true }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if cameraType == .sony, usbSerial != nil { return true }
        if isBluetooth { return true }
        if cameraType == .sony, sonyWebRemote, usbSerial == nil {
            return !password.isEmpty  // the Web Remote needs the camera's login (there is no factory password)
        }
        if cameraType == .sony {
            return !accessAuthentication || !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if cameraType == .blackmagic, bmRemoteControl {
            return !password.isEmpty
        }
        if cameraType == .blackmagic, bmLogin {
            return !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true  // blackmagic, ARRI: host only
    }

    private var connectionFooter: String {
        switch cameraType {
        case .demo: return "A simulated camera, for trying layouts without hardware."
        case .arri:
            return "ALEXA Mini, Mini LF, ALEXA 35 or AMIRA, over the camera's Web Remote. No login: put the camera's Ethernet (or Wi-Fi) on this network and enter its address, from its network settings."
        case .blackmagic where isBluetooth:
            return "Over Bluetooth, within the same room. The first time, the camera shows a 6-digit code to type into the pairing prompt that comes up. No battery, media or live view this way."
        case .blackmagic where bmRemoteControl:
            return blackmagicCable + BlackmagicAccessPicker.remoteControlFooter
        case .blackmagic:
            let login = bmLogin
                ? " Login: the user name and password under Network Access → Secure Login in Blackmagic Camera Setup."
                : " Login only if the camera has one set."
            if bmUseHTTPS {
                return blackmagicCable + "On if the camera's network access uses HTTPS (Generate Certificate in Blackmagic Camera Setup). Its certificate is remembered the first time; you're asked if it changes." + login
            }
            return blackmagicCable + "Turn on Network Access in the camera's setup first." + login
        case .sony where usbSerial != nil:
            return "On a USB-C cable to this Mac, with the camera's USB Connection Mode set to Remote Shooting. No login, and live view runs at the camera's own rate."
        case .sony where sonyWebRemote:
            return "VENICE / VENICE 2 over its Web Remote. Set a password on the camera (Technical > Authentication; 8+ characters, letters and numbers) and enter it here. User is admin by default."
        case .sony:
            if accessAuthentication {
                return "Use the user and password from the camera's Access Authen. Info screen. Its fingerprint is saved on first connect, and you're only asked about it if it ever changes."
            }
            return "With Access Authentication off on the camera, open its Pairing menu the first time and approve this device."
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            label = store.nextFreeLabel()
            color = store.nextFreeColor()
            bmRemoteControl = true  // no computer needed, if the camera has it; the address's answer may change it
        case .existing(let id):
            guard let saved = store.savedCamera(id) else { return }
            label = saved.slot.label
            color = saved.slot.color
            customColor = saved.slot.customColor
            host = saved.slot.host
            switch saved.connection {
            case .demo(let body):
                cameraType = .demo
                demoBody = body
            case .sony(let sony):
                cameraType = .sony
                sonyWebRemote = false
                protocolPickedByHand = true
                accessAuthentication = sony.usesAccessAuthentication
                username = sony.username ?? ""
                fingerprint = sony.trustedFingerprint
                password = store.credentials.password(for: id) ?? ""
            case .venice(let venice):
                cameraType = .sony
                sonyWebRemote = true
                protocolPickedByHand = true  // a saved camera keeps its protocol
                username = venice.username ?? "admin"
                password = store.credentials.password(for: id) ?? ""
            case .arri:
                cameraType = .arri
            case .blackmagicBluetooth(let bt):
                cameraType = .blackmagic
                bluetoothName = bt.name
            case .blackmagic(let bm):
                cameraType = .blackmagic
                bmUseHTTPS = bm.useHTTPS
                bmFingerprint = bm.pinnedCertificateFingerprint
                bmLogin = bm.username != nil
                username = bm.username ?? ""
                bmRemoteControl = bm.remoteControl
                bmAccessPickedByHand = true
                password = store.credentials.password(for: id) ?? ""
            }
        }
    }

    private func save() {
        let cleanLabel = String(label.trimmingCharacters(in: .whitespaces).prefix(3)).uppercased()
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        let connection: CameraConnection
        let secret: String?
        switch cameraType {
        case .demo:
            connection = .demo(demoBody)
            secret = nil
        case .sony where sonyWebRemote && usbSerial == nil:
            connection = .venice(VeniceConnection(
                host: cleanHost,
                username: username.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "admin" : username.trimmingCharacters(in: .whitespaces)))
            secret = password.isEmpty ? nil : password
        case .sony:
            let login = accessAuthentication && usbSerial == nil
            connection = .sony(SonyConnection(
                username: login ? username.trimmingCharacters(in: .whitespaces) : nil,
                trustedFingerprint: login ? fingerprint : nil))
            secret = login ? password : nil
        case .arri:
            connection = .arri(ArriConnection(host: cleanHost))
            secret = nil
        case .blackmagic where isBluetooth:
            connection = .blackmagicBluetooth(BlackmagicBluetoothConnection(
                peripheralID: BluetoothCameraAddress.id(in: cleanHost)!, name: bluetoothName))
            secret = nil
        case .blackmagic where bmRemoteControl:
            connection = .blackmagic(BlackmagicConnection(host: cleanHost, useHTTPS: true,
                                                          pinnedCertificateFingerprint: bmFingerprint, remoteControl: true))
            secret = password
        case .blackmagic:
            connection = .blackmagic(BlackmagicConnection(
                host: cleanHost,
                useHTTPS: bmUseHTTPS,
                pinnedCertificateFingerprint: bmUseHTTPS ? bmFingerprint : nil,
                username: bmLogin ? username.trimmingCharacters(in: .whitespaces) : nil))
            secret = bmLogin ? password : nil
        }
        switch target {
        case .new:
            store.addCamera(label: cleanLabel, color: color, customColor: customColor, host: cleanHost, connection: connection,
                            password: secret)
        case .existing(let id):
            store.updateCamera(id, label: cleanLabel, color: color, customColor: .some(customColor), host: cleanHost,
                               connection: connection, password: secret ?? "")
        }
    }
}

/// One-line description of how a camera connects, for lists.
func connectionSummary(_ connection: CameraConnection?) -> String {
    switch connection {
    case .demo(let body): "Demo · \(body.displayName)"
    case .sony(let sony):
        !sony.usesAccessAuthentication ? "Sony · pairing"
            : (sony.username ?? "").isEmpty ? "Sony · Access Authentication" : "Sony · user \(sony.username ?? "")"
    case .venice(let venice): "VENICE · \(venice.username ?? "admin") · \(venice.host)"
    case .arri(let arri): "ARRI · \(arri.host)"
    case .blackmagic(let bm) where bm.remoteControl:
        "Blackmagic · Remote Control · \(bm.host)"
    case .blackmagic(let bm):
        "Blackmagic · \(bm.username.map { "user \($0) · " } ?? "")\(bm.useHTTPS ? "https://" : "")\(bm.host)"
    case .blackmagicBluetooth(let bt): "Blackmagic · Bluetooth · \(bt.name)"
    case nil: ""
    }
}

struct PageEditor: View {
    let store: DashboardStore
    let target: EditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var showsAll = false
    @State private var fitsScreen = true
    @State private var confirmingDelete = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(showsAll ? "All" : store.autoName(for: orderedSelection)))
                } footer: {
                    FooterText("Leave blank to name it after its cameras.")
                }
                Section {
                    Toggle("Every camera", isOn: $showsAll)
                    if !showsAll {
                        ForEach(store.cameras) { camera in
                            Button {
                                if selected.contains(camera.id) { selected.remove(camera.id) } else { selected.insert(camera.id) }
                            } label: {
                                HStack {
                                    Text(camera.slot.label)
                                        .font(Theme.mono(16, weight: .heavy))
                                        .foregroundStyle(camera.slot.tint)
                                        .lineLimit(1)
                                        .fixedSize()
                                        .frame(minWidth: 28, alignment: .leading)
                                    Text(camera.state.modelName ?? connectionSummary(store.savedCamera(camera.id)?.connection))
                                        .foregroundStyle(Theme.sheet.text)
                                    Spacer()
                                    if selected.contains(camera.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.sheet.needle)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Cameras")
                } footer: {
                    FooterText("One camera gets the big single-camera layout; several share the screen.")
                }
                Section {
                    Toggle("Fit to Screen", isOn: $fitsScreen)
                } footer: {
                    FooterText(fitsScreen
                        ? "Tiles shrink so the whole page fits, but not below a size that's still easy to read and tap; past that the page scrolls."
                        : "Tiles keep the size of the page's automatic layout and the page scrolls, so you can keep adding tiles below.")
                }
                if case .existing(let id) = target, store.pages.count > 1 {
                    Section {
                        // Asked first, as from the page tab's menu: it was one tap, with no undo.
                        Button("Delete Page…", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete the page \(store.pages.first { $0.id == id }?.name ?? "")?",
                                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                                Button("Delete Page", role: .destructive) {
                                    store.removePage(id)
                                    dismiss()
                                }
                            } message: {
                                Text("Its layout goes with it. The cameras stay.")
                            }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(target.isNew ? "Add Page" : "Edit Page")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.isNew ? "Add" : "Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!showsAll && selected.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 560)
        #endif
    }

    /// Selected cameras in dashboard order (A, B, C…), not tap order.
    private var orderedSelection: [UUID] {
        store.cameras.map(\.id).filter { selected.contains($0) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard case .existing(let id) = target, let page = store.pages.first(where: { $0.id == id }) else { return }
        selected = Set(page.cameraIDs)
        showsAll = page.showsAllCameras
        fitsScreen = !page.isScrolling
        // Keep auto-generated names automatic, so "A+B" follows the cameras if they change.
        let auto = page.showsAllCameras ? "All" : store.autoName(for: page.cameraIDs)
        name = page.name == auto ? "" : page.name
    }

    private func save() {
        switch target {
        case .new:
            let page = store.addPage(name: name, cameraIDs: orderedSelection, showsAllCameras: showsAll)
            store.setPageScrolls(page.id, !fitsScreen)
        case .existing(let id):
            store.updatePage(id, name: name, cameraIDs: orderedSelection, showsAllCameras: showsAll)
            store.setPageScrolls(id, !fitsScreen)
        }
    }
}

/// Renders ControlAPISettingsView with a running server, for the dashboard-snapshot tool.
@MainActor
struct ControlAPIDebugScreen: View {
    let store: DashboardStore
    @State private var tokenStore = ControlServerTokenStore()
    @State private var server: ControlServer? = nil

    var body: some View {
        Group {
            if let s = server {
                NavigationStack {
                    ControlAPISettingsView(store: store, server: s, tokenStore: tokenStore)
                }
            } else {
                NavigationStack {
                    ProgressView("Starting server…")
                }
            }
        }
        .task {
            let s = ControlServer(tokenStore: tokenStore, store: store)
            try? s.start()
            try? await Task.sleep(for: .milliseconds(300))
            server = s
        }
    }
}

/// The eight camera colors, and a ninth swatch for any other: its eyedropper opens the system's
/// color picker, and the swatch takes the color picked. Picking one of the eight drops it.
struct ColorChooser: View {
    @Binding var selection: SlotColor
    @Binding var custom: AppearanceSettings.RGB?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SlotColor.allCases, id: \.self) { color in
                Button {
                    selection = color
                    custom = nil
                } label: {
                    ColorSwatch(fill: color.color, selected: custom == nil && selection == color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
            }
            CustomColorSwatch(custom: $custom)
        }
        .padding(.vertical, 4)
    }
}

private struct ColorSwatch: View {
    let fill: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 2.5 : 0))
    }
}

/// The ninth swatch: an eyedropper, on the color picked or on a ring of colors until there is one. A tap opens Tiles'
/// color picker from it (`ColourPickerPanel`).
private struct CustomColorSwatch: View {
    @Binding var custom: AppearanceSettings.RGB?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            ZStack {
                if let custom {
                    ColorSwatch(fill: Color(custom), selected: true)
                } else {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center),
                                      lineWidth: 3)
                        .frame(width: 26, height: 26)
                }
                Image(systemName: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(custom.map { $0.isLight ? Color.black : .white } ?? Theme.sheet.text)
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .colourPicker(isPresented: $picking, title: "Custom Color", rgb: picked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Custom Color")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("customColour")
    }

    /// The picker starts on the camera's own color, or white until it has one; a pick makes it its own.
    private var picked: Binding<AppearanceSettings.RGB> {
        Binding(get: { custom ?? .white }, set: { custom = $0 })
    }
}

/// Profiles section shown at the top of Add Camera. One row per profile; tapping fills the form fields.
/// Hidden when there are no profiles. Already-added addresses show "Added" and are disabled.
struct ProfilesSection: View {
    let profiles: [CameraProfileRecord]
    let existingHosts: Set<String>
    /// The address currently in the form, so the row it came from shows a checkmark.
    let selectedHost: String
    let onSelect: (CameraProfileRecord) -> Void

    var body: some View {
        Section {
            ForEach(profiles) { profile in
                let added = profile.isAdded(in: existingHosts)
                let selected = profile.address.trimmingCharacters(in: .whitespaces) == selectedHost.trimmingCharacters(in: .whitespaces)
                SelectableRow(title: profile.name, subtitle: profile.address, isAdded: added, isSelected: selected) {
                    onSelect(profile)
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            FooterText("Tap a profile to fill in the form from it.")
        }
    }
}

// MARK: - Profile List

/// Settings → Camera Profiles. Pushed inside Settings' navigation stack, so it has no stack of its own.
struct ProfileListView: View {
    let store: DashboardStore
    @State private var profileTarget: EditorTarget?

    var body: some View {
        Form {
            Section {
                ForEach(store.profiles) { profile in
                    Button { profileTarget = .existing(profile.id) } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(profile.tint)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(Theme.sheet.text)
                                Text(profile.address)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.sheet.secondaryText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onMove { store.moveProfiles(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    let ids = offsets.map { store.profiles[$0].id }
                    ids.forEach(store.removeProfile)
                }
                Button { profileTarget = .new } label: {
                    Label("Add Profile", systemImage: "plus")
                }
            } header: {
                Text("Profiles")
            } footer: {
                FooterText("A profile is a saved camera you can add in one tap. Adding or removing a camera from the dashboard never changes a profile.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Camera Profiles")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            #endif
        }
        .sheet(item: $profileTarget) { ProfileEditor(store: store, target: $0) }
    }
}

// MARK: - Profile Editor

/// Creates or edits a camera profile.
struct ProfileEditor: View {
    let store: DashboardStore
    let target: EditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var profileType: ProfileCameraType = .sony
    @State private var letter = ""
    @State private var color: SlotColor = .red
    @State private var customColor: AppearanceSettings.RGB?
    @State private var accessAuthentication = true
    @State private var bmLogin = false
    @State private var username = ""
    @State private var password = ""
    @State private var useHTTPS = false
    @State private var bmRemoteControl = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name, prompt: Text("FX5 · Studio"))
                    TextField("Address", text: $address, prompt: Text("IP address"))
                        .modifier(HostFieldStyle())
                }
                Section {
                    Picker("Type", selection: $profileType) {
                        ForEach(ProfileCameraType.allCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch profileType {
                    case .sony:
                        Toggle("Access Authentication", isOn: $accessAuthentication)
                        if accessAuthentication {
                            CredentialFields(username: $username, password: $password, note: CredentialFields.sony)
                        }
                    case .blackmagic:
                        BlackmagicAccessPicker(remoteControl: $bmRemoteControl)
                        if bmRemoteControl {
                            CredentialFields(username: nil, password: $password, passwordTitle: "Remote Password",
                                             note: CredentialFields.blackmagicRemote)
                        } else {
                            Toggle("Login", isOn: $bmLogin)
                            if bmLogin {
                                CredentialFields(username: $username, password: $password, note: CredentialFields.blackmagic)
                            }
                            Toggle("HTTPS", isOn: $useHTTPS)
                        }
                    case .arri:
                        Text("No login: an ARRI camera's Web Remote has none.")
                            .font(.footnote)
                            .foregroundStyle(Theme.sheet.secondaryText)
                    }
                } header: {
                    Text("Connection")
                }
                Section("Defaults") {
                    TextField("Label", text: $letter, prompt: Text("A  (optional)"))
                    LabeledContent("Color") {
                        ColorChooser(selection: $color, custom: $customColor)
                    }
                }
                if case .existing(let id) = target {
                    Section {
                        Button("Delete Profile", role: .destructive) {
                            store.removeProfile(id)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(target.isNew ? "Add Profile" : "Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.isNew ? "Add" : "Save") {
                        saveProfile()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 520)
        #endif
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if target.isNew { bmRemoteControl = true }
        guard case .existing(let id) = target,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }
        name = profile.name
        address = profile.address
        profileType = profile.cameraType
        letter = profile.letter ?? ""
        color = profile.color
        customColor = profile.customColor
        accessAuthentication = profile.useAccessAuthentication
        bmLogin = profile.cameraType == .blackmagic && profile.useAccessAuthentication
        username = profile.username ?? ""
        useHTTPS = profile.useHTTPS
        bmRemoteControl = profile.cameraType == .blackmagic && profile.remoteControl == true
        password = store.credentials.profilePassword(for: id) ?? ""
    }

    private func saveProfile() {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        let cleanAddress = address.trimmingCharacters(in: .whitespaces)
        let cleanLetter = letter.trimmingCharacters(in: .whitespaces)
        let cleanUser = username.trimmingCharacters(in: .whitespaces)
        // A login: Sony's Access Authentication, or a Blackmagic camera's network access login or remote password.
        let remote = profileType == .blackmagic && bmRemoteControl
        let login = profileType == .sony ? accessAuthentication : profileType == .blackmagic ? bmLogin || remote : false
        let secret: String? = (login && !password.isEmpty) ? password : nil

        switch target {
        case .new:
            let profile = CameraProfileRecord(
                name: cleanName, address: cleanAddress, cameraType: profileType,
                letter: cleanLetter.isEmpty ? nil : String(cleanLetter.prefix(3)).uppercased(),
                color: color, customColor: customColor, useAccessAuthentication: login,
                username: login && !remote ? cleanUser : nil,
                useHTTPS: profileType == .blackmagic && (useHTTPS || remote),
                remoteControl: remote ? true : nil
            )
            store.addProfile(profile, password: secret)
        case .existing(let id):
            let updated = CameraProfileRecord(
                id: id, name: cleanName, address: cleanAddress, cameraType: profileType,
                letter: cleanLetter.isEmpty ? nil : String(cleanLetter.prefix(3)).uppercased(),
                color: color, customColor: customColor, useAccessAuthentication: login,
                username: login && !remote ? cleanUser : nil,
                useHTTPS: profileType == .blackmagic && (useHTTPS || remote),
                remoteControl: remote ? true : nil
            )
            store.updateProfile(id, with: updated, password: secret)
        }
    }
}

// MARK: - Save as Profile sheet

/// Prompt for the profile name, then saves the camera as a profile.
struct SaveAsProfileSheet: View {
    let store: DashboardStore
    let cameraID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $name, prompt: Text("e.g. FX5 · Studio"))
                } footer: {
                    FooterText("Saves this camera's address, type, and credentials as a profile for quick reuse.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Save as Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveAsProfile(from: cameraID, name: name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let camera = store.cameras.first(where: { $0.id == cameraID }) {
                    name = camera.lastSeen?.model.flatMap { m in
                        // Short model name, e.g. ILME-FX3 → FX3
                        if let dash = m.firstIndex(of: "-") { return String(m[m.index(after: dash)...]) }
                        return nil
                    } ?? camera.slot.label
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 200, idealHeight: 240)
        #endif
    }
}

/// How Tiles gets into a Blackmagic camera: its Network Access (Blackmagic Camera Setup), or its Remote Control (set up
/// on the camera itself, with only a remote password).
struct BlackmagicAccessPicker: View {
    @Binding var remoteControl: Bool

    var body: some View {
        Picker("Connect With", selection: $remoteControl) {
            Text("Network Access").tag(false)
            Text("Remote Control").tag(true)
        }
    }

    static let remoteControlFooter = "On the camera itself: Setup, page 13, Remote Control on (\"control and monitor\"), with a remote password. Network Access can stay off in Blackmagic Camera Setup. Tiles connects on port 444; the camera's certificate is remembered the first time, and you're asked if it changes."
}

struct HostFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}

/// Renames LUTs in the picker. Lists what the connected cameras have, then anything renamed before.
struct LUTNamesView: View {
    let store: DashboardStore

    var body: some View {
        Form {
            Section {
                if names.isEmpty {
                    Text("Connect a camera to see its LUTs.")
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                ForEach(names, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(Theme.sheet.secondaryText)
                        TextField(lutTitle(name, names: [:]), text: binding(name))
                            .autocorrectionDisabled()
                    }
                }
            } footer: {
                FooterText("Leave a name blank to use the camera's. Every camera with a LUT of that name shows yours.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("LUT Names")
    }

    /// The cameras' LUTs in the order they list them, then names renamed earlier that no camera reports now.
    private var names: [String] {
        var all: [String] = []
        for camera in store.cameras {
            for name in camera.state.lut?.options ?? [] where !all.contains(name) { all.append(name) }
        }
        for name in store.lutNames.keys.sorted() where !all.contains(name) { all.append(name) }
        return all
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { store.lutNames[name] ?? "" },
                set: { store.lutNames[name] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
}

