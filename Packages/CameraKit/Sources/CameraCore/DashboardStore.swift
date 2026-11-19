import Foundation
import Observation

/// Every camera the app knows about, the pages that group them, and which page is showing.
@MainActor
@Observable
public final class DashboardStore {
    public private(set) var cameras: [CameraController] = []

    /// A camera is connected or on its way (connecting, waiting for approval on the body, resyncing).
    public var isUsingACamera: Bool {
        cameras.contains {
            switch $0.state.connection {
            case .connecting, .awaitingApproval, .connected, .stale: true
            case .disconnected, .fingerprintChanged, .failed: false
            }
        }
    }

    /// App to the background / foreground (iOS): close every camera cleanly, then reconnect on return.
    /// Also stops / resumes HaLow polling — nothing polls in the background. A camera held for the Terms of Use stays
    /// unconnected: resuming would connect it.
    public func suspendAll() {
        cameras.filter { !isHeld($0) }.forEach { $0.suspend() }
        withHaLowMonitor { await $0.setForeground(false) }
    }
    public func resumeAll() {
        cameras.filter { !isHeld($0) }.forEach { $0.resume() }
        withHaLowMonitor { await $0.setForeground(true) }
    }

    /// Cameras other than demos wait for the Terms of Use (`TermsOfUse`): Sony's terms have to be agreed to before
    /// anyone uses Tiles with a camera. The dashboard asks while this is true; `agreeToTerms()` lets them connect.
    public private(set) var holdsRealCameras = false

    /// The Terms of Use were agreed to: saved (with the version and when), and the cameras held for them connect.
    public func agreeToTerms(at date: Date = Date()) {
        if let defaults { TermsOfUse.accept(in: defaults, at: date) }
        guard holdsRealCameras else { return }
        holdsRealCameras = false
        cameras.forEach { startIfAllowed($0) }   // `start` is once only: the demos already running carry on
        watchUSB()
    }

    /// What this device agreed to (Settings → About). nil for a store that isn't saved.
    public var termsAcceptance: TermsOfUse.Acceptance? { defaults.flatMap(TermsOfUse.acceptance(in:)) }

    private func isHeld(_ camera: CameraController) -> Bool { holdsRealCameras && !camera.isDemo }

    private func startIfAllowed(_ controller: CameraController) {
        guard startsCameras, !isHeld(controller) else { return }
        controller.start()
    }
    public private(set) var pages: [CameraPage] = []
    public private(set) var currentPageID: UUID?
    /// The padlock: locked, the app's tiles don't take a touch, though the Control API's commands still work. Here, not
    /// in the view, so the API can read and set it. Not saved: every launch starts unlocked.
    public var controlsLocked = false

    @ObservationIgnored private var saved: [UUID: SavedCamera] = [:]
    @ObservationIgnored private var usbArrivals: USBCameraArrivals?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let startsCameras: Bool
    @ObservationIgnored private let makeBackend: BackendFactory
    @ObservationIgnored public let credentials: any CredentialStore

    // MARK: HaLow monitoring

    /// The HaLow nodes found or added, this device's own first, as the monitor last reported them.
    public private(set) var haLowNodes: [HaLowNode] = [] {
        didSet { if !haLowNodes.isEmpty { haLowSeen = true } }
    }

    /// A HaLow node has been found on this device, now or on an earlier run: from then on automatic pages show the
    /// HaLow tile, so they don't change shape at launch while the monitor looks again. Persisted under `haLowSeenKey`.
    public private(set) var haLowSeen = false {
        didSet {
            guard haLowSeen != oldValue else { return }
            defaults?.set(haLowSeen, forKey: Self.haLowSeenKey)
            for camera in cameras { camera.haLowAvailable = haLowSeen }
        }
    }
    static let haLowSeenKey = "halow.seen.v1"

    /// HaLow display mode, nodes added by hand, login. Persisted separately under `haLowSettingsKey`.
    public var haLowSettings: HaLowSettings = HaLowSettings() {
        didSet { saveHaLowSettings(); applyHaLowSettings() }
    }

    /// Shares the app's credential store, where Settings saves the nodes' password.
    @ObservationIgnored private let haLowMonitor: HaLowMonitor
    static let haLowSettingsKey = "halow.settings.v1"

    /// Add Camera lists the devices on the mesh once a node is known and HaLow isn't Off.
    public var offersMeshDevices: Bool {
        meshPreview != nil || (!haLowNodes.isEmpty && haLowSettings.displayMode != .off)
    }

    /// Previews and snapshots: what `scanMesh()` returns instead of asking the nodes.
    @ObservationIgnored public var meshPreview: MeshDeviceScan?
    @ObservationIgnored private var haLowPreviewing = false
    @ObservationIgnored private var haLowQueue: Task<Void, Never>?

    /// Renders of the app as people see it with their own cameras (the App Store's screenshots): demo cameras drawn as
    /// real ones, without "demo" by their names.
    public func previewAsRealCameras() {
        for camera in cameras { camera.isDemo = false }
    }

    /// Previews and snapshots: these nodes, and nothing looked for or polled.
    public func previewHaLowNodes(_ nodes: [HaLowNode]) {
        haLowPreviewing = true
        haLowNodes = nodes
    }

    /// The devices on the HaLow mesh, read from the nodes now (DHCP leases and static leases). One read for Add Camera's
    /// two lists that want it as it opens (the mesh's devices, and the cameras on the network), and a refresh within 5 s.
    public func scanMesh() async -> MeshDeviceScan {
        if let meshPreview { return meshPreview }
        if let meshScan, Date().timeIntervalSince(meshScan.started) < 5 { return await meshScan.task.value }
        let monitor = haLowMonitor
        let task = Task { await monitor.meshDevices() }
        meshScan = (Date(), task)
        return await task.value
    }
    @ObservationIgnored private var meshScan: (started: Date, task: Task<MeshDeviceScan, Never>)?

    static let storageKey = "dashboard.v1"

    // MARK: Camera Profiles

    /// The user's profile library. Profiles are templates; adding or removing a camera never changes them.
    public private(set) var profiles: [CameraProfileRecord] = []

    /// Load Tiles' false color LUT onto an FX3 that connects without one, so the LUT tile's False Color switch
    /// works without the camera having a false color LUT pre-loaded. First empty User slot only.
    public var addsFalseColorLUT = true {
        didSet { defaults?.set(addsFalseColorLUT, forKey: "lut.addsFalseColor") }
    }

    /// Test Mode: a camera that isn't connected runs as a working demo of itself on every page, not only in edit mode,
    /// so its pages can be laid out and tried with it off (`previewController(for:)`). Nothing reaches the camera;
    /// it takes over when it connects.
    public var testMode = false {
        didSet {
            guard testMode != oldValue else { return }
            defaults?.set(testMode, forKey: Self.testModeKey)
            // The stand-ins are made again, working ones or still ones.
            previews.values.forEach { $0.controller.disconnect() }
            previews = [:]
        }
    }
    static let testModeKey = "testMode.v1"

    /// Test Mode's word when a camera goes live, or drops out to its demo of itself: the values on a page must never
    /// switch between a camera's and a demo's without a word. Shown for a moment; not saved.
    public private(set) var testModeNotice: TestModeNotice?
    /// Whether each camera was connected at its last report, to see that change.
    @ObservationIgnored private var wasConnected: [UUID: Bool] = [:]

    /// A camera's connection changed: one that's back takes over from its demo, which stops, and in Test Mode the
    /// change is said (`testModeNotice`). A camera's first report isn't a change.
    func noteConnectionChange(_ camera: CameraController) {
        let connected = camera.state.connection.isControllable
        guard !camera.isDemo, let before = wasConnected.updateValue(connected, forKey: camera.id), before != connected
        else { return }
        if connected, let preview = previews.removeValue(forKey: camera.id) { preview.controller.disconnect() }
        guard testMode else { return }
        testModeNotice = TestModeNotice(cameraID: camera.id, label: camera.slot.label, isLive: connected)
    }

    public func dismissTestModeNotice(_ id: UUID) {
        if testModeNotice?.id == id { testModeNotice = nil }
    }

    /// Previews and snapshots: this notice showing.
    public func previewTestModeNotice(_ notice: TestModeNotice) {
        testModeNotice = notice
    }

    /// What the LUT picker calls a LUT, keyed by the camera's name for it (set in Settings). Shared by every camera:
    /// the same file loaded on two bodies has the same name. The cameras keep their own names.
    public var lutNames: [String: String] = [:] {
        didSet { defaults?.set(try? JSONEncoder().encode(lutNames), forKey: "lut.names") }
    }
    /// Cameras already checked on their current connection: once per connection, not on every state update.
    @ObservationIgnored var falseColorChecked: Set<UUID> = []
    /// The LUT's bytes. Tests swap in their own.
    @ObservationIgnored var falseColorLUTData: () -> Data? = { BundledLUT.falseColor }

    private struct Snapshot: Codable {
        /// Bumped when the saved shape changes incompatibly.
        /// 1 = cameras, pages, optional page layouts.
        /// 2 = v1 layouts reset (pre-offer-aware templates had placeholders and odd gaps).
        /// 3 = untouched v2 layouts reset (identity-strip reorder).
        /// 4 = FX3-family solo page offered once; pre-v4 cameras count as already offered.
        /// 5 = camera profiles library added.
        /// 6 = untouched v3 layouts reset (Playback tile added to templates).
        /// 7 = Live View split into the picture tile and a button: saved Live View tiles become buttons.
        /// 8 = an iPhone shows its own column for a customized page: arrangements that are the old reflow, untouched,
        ///     go back to automatic.
        /// 9 = untouched v4 layouts reset (ND − and ND + added to every 4-wide block with an ND tile), and every
        ///     Web GUI tile taken off (the tile is gone).
        /// 10 = untouched v5 layouts reset (De-squeeze added to the Blackmagic block, under Codec).
        /// 11 = untouched v6 layouts reset (Battery and Media as separate tiles in every block's identity strip).
        var version: Int? = 11

        /// Brings an older saved setup up to date.
        func migrated() -> Snapshot {
            var snapshot = self
            if (version ?? 1) < 2 {
                snapshot.pages = pages.map { var page = $0; page.layout = nil; return page }
            }
            if (version ?? 1) < 3 {
                snapshot.pages = snapshot.pages.map { snapshot.untouchedLayoutsDropped($0, templates: LayoutTemplates.v2, renameFX30: true) }
            }
            if (version ?? 1) < 4 {
                snapshot.cameras = snapshot.cameras.map { camera in
                    var camera = camera
                    let hasSoloPage = snapshot.pages.contains { !$0.showsAllCameras && $0.cameraIDs == [camera.slot.id] }
                    if hasSoloPage || camera.lastSeen?.isFX3Family == true { camera.soloPageOffered = true }
                    return camera
                }
            }
            // v4 → v5: profiles array didn't exist; default to empty (already happens via decodeIfPresent).
            if (version ?? 1) < 6 {
                snapshot.pages = snapshot.pages.map { snapshot.untouchedLayoutsDropped($0, templates: LayoutTemplates.v3, renameFX30: false) }
            }
            // The picture only showed in a Live View tile 66 pt or taller, and the ones in use were the button; the
            // picture tile is new in Add Tile.
            if (version ?? 1) < 7 {
                snapshot.pages = snapshot.pages.map { page in
                    var page = page
                    page.layout = page.layout?.replacingKind(.liveView, with: .liveViewButton)
                    page.phoneLayouts = page.phoneLayouts?.mapValues { $0.replacingKind(.liveView, with: .liveViewButton) }
                    return page
                }
            }
            if (version ?? 1) < 8 {
                snapshot.pages = snapshot.pages.map(snapshot.reflowedPhoneLayoutsDropped)
            }
            // Only the 4-wide blocks changed: an iPhone's own arrangements stay as they are.
            if (version ?? 1) < 9 {
                snapshot.pages = snapshot.pages.map {
                    snapshot.untouchedLayoutsDropped($0, templates: LayoutTemplates.v4, renameFX30: false, phones: false)
                }
                snapshot.pages = snapshot.pages.map(Snapshot.webGUIRemoved)
            }
            // Only the Blackmagic block changed: pages without a Blackmagic camera stay as they are.
            if (version ?? 1) < 10 {
                let blackmagic = Set(snapshot.cameras.filter {
                    $0.connection.blackmagic != nil || $0.demoBody?.isBlackmagic == true || $0.lastSeen?.make == .blackmagic
                }.map(\.slot.id))
                snapshot.pages = snapshot.pages.map { page in
                    page.cameraIDs.contains(where: blackmagic.contains)
                        ? snapshot.untouchedLayoutsDropped(page, templates: LayoutTemplates.v5, renameFX30: false, phones: false)
                        : page
                }
            }
            // All blocks changed: every page with any camera may have the old identity strip.
            if (version ?? 1) < 11 {
                snapshot.pages = snapshot.pages.map {
                    snapshot.untouchedLayoutsDropped($0, templates: LayoutTemplates.v6, renameFX30: false)
                }
            }
            snapshot.version = 11
            return snapshot
        }

        /// Takes every Web GUI tile off: its web page and Tiles connected at once can trip a camera up.
        /// The tile is gone from Add Tile; any saved on earlier layouts come off here, and their row closes
        /// up (`closingGaps`): Playback takes the bottom row back.
        static func webGUIRemoved(_ page: CameraPage) -> CameraPage {
            func removed(_ layout: PageLayout) -> PageLayout {
                layout.widgets.contains { $0.kind == .webGUI }
                    ? LayoutTemplates.closingGaps(in: layout, keeping: { $0.kind != .webGUI }) : layout
            }
            var page = page
            page.layout = page.layout.map(removed)
            page.phoneLayouts = page.phoneLayouts?.mapValues(removed)
            return page
        }

        /// Drops iPhone arrangements that are exactly the reflow of the page an iPhone used to show (`compact`), so
        /// the phone follows its own column instead of keeping a copy nobody changed.
        private func reflowedPhoneLayoutsDropped(_ page: CameraPage) -> CameraPage {
            guard let layout = page.layout, var phones = page.phoneLayouts else { return page }
            let profiles = Dictionary(cameras.map { ($0.slot.id, $0.lastSeen) }, uniquingKeysWith: { first, _ in first })
            let offered = PageLayout(columns: layout.columns, widgets: layout.widgets.filter {
                profiles[$0.cameraID]??.offered.contains($0.kind) ?? true
            })
            for (cameraID, phone) in phones where phone.sameArrangement(as: LayoutTemplates.compact(offered, camera: cameraID)) {
                phones[cameraID] = nil
            }
            var page = page
            page.phoneLayouts = phones.isEmpty ? nil : phones
            return page
        }

        /// Resets a page's layout (and iPhone layouts) to nil when they exactly match what the app built from
        /// `templates`, so they follow the current defaults rather than freezing on the old ones. When
        /// `renameFX30` is true, also fixes the FX30's auto-page name from the old "<letter> FX3" form.
        private func untouchedLayoutsDropped(_ page: CameraPage, templates: LayoutTemplates.TemplateSet,
                                             renameFX30: Bool, phones checksPhones: Bool = true) -> CameraPage {
            var page = page
            let profileMap = Dictionary(cameras.map { ($0.slot.id, $0.lastSeen) }, uniquingKeysWith: { first, _ in first })
            let profile: (UUID) -> CameraProfile? = { profileMap[$0] ?? nil }
            let order = cameras.map(\.slot.id)
            let shown = page.showsAllCameras ? order : order.filter { page.cameraIDs.contains($0) }
            if checksPhones, var phones = page.phoneLayouts {
                for (cameraID, phone) in phones {
                    let narrow = PageLayout(columns: LayoutTemplates.narrowColumns,
                                           widgets: LayoutTemplates.block(camera: cameraID, profile: profile(cameraID),
                                                                          wide: false, templates: templates))
                    var candidates = [narrow]
                    if renameFX30, let layout = page.layout {
                        candidates.append(LayoutTemplates.compact(PageLayout(columns: layout.columns, widgets: layout.widgets.filter {
                            profile($0.cameraID)?.offered.contains($0.kind) ?? true
                        }), camera: cameraID))
                    }
                    if candidates.contains(where: { phone.sameArrangement(as: $0) }) { phones[cameraID] = nil }
                }
                page.phoneLayouts = phones.isEmpty ? nil : phones
            }
            if let layout = page.layout,
               layout.sameArrangement(as: LayoutTemplates.materialize(cameraIDs: shown, profile: profile,
                                                                      templates: templates)) {
                page.layout = nil
            }
            if renameFX30, page.layout == nil, page.cameraIDs.count == 1,
               let camera = cameras.first(where: { $0.slot.id == page.cameraIDs[0] }),
               page.name == "\(camera.slot.label) FX3", let model = camera.lastSeen?.model, model.hasSuffix("FX30") {
                page.name = "\(camera.slot.label) FX30"
            }
            return page
        }

        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
        var profiles: [CameraProfileRecord]?

        init(cameras: [SavedCamera], pages: [CameraPage], currentPageID: UUID?, profiles: [CameraProfileRecord]?) {
            self.cameras = cameras
            self.pages = pages
            self.currentPageID = currentPageID
            self.profiles = profiles
        }

        private enum CodingKeys: String, CodingKey { case version, cameras, pages, currentPageID, profiles }

        /// A camera or profile this build can't read — a kind of camera added by a newer build — is left out,
        /// rather than failing the whole setup and starting over empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version)
            cameras = try container.decode([Lenient<SavedCamera>].self, forKey: .cameras).compactMap(\.value)
            pages = try container.decode([CameraPage].self, forKey: .pages)
            currentPageID = try container.decodeIfPresent(UUID.self, forKey: .currentPageID)
            profiles = try container.decodeIfPresent([Lenient<CameraProfileRecord>].self, forKey: .profiles)?
                .compactMap(\.value)
        }
    }

    /// - Parameters:
    ///   - defaults: where to persist; nil keeps everything in memory (previews, tests).
    ///   - startCameras: connect each camera as it's created.
    ///   - holdsRealCameras: only demo cameras connect until `agreeToTerms()` (the app, before the Terms of Use).
    ///   - initialStates: state to show before a backend reports anything (previews).
    public init(
        cameras: [SavedCamera],
        pages: [CameraPage],
        currentPageID: UUID? = nil,
        profiles: [CameraProfileRecord] = [],
        defaults: UserDefaults? = nil,
        startCameras: Bool = true,
        holdsRealCameras: Bool = false,
        initialStates: [UUID: CameraState] = [:],
        credentials: any CredentialStore = InMemoryCredentialStore(),
        makeBackend: @escaping BackendFactory = DashboardStore.demoOnlyBackend
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.haLowMonitor = HaLowMonitor(credentialStore: credentials)
        self.startsCameras = startCameras
        self.holdsRealCameras = holdsRealCameras
        self.makeBackend = makeBackend
        self.pages = pages
        self.currentPageID = currentPageID ?? pages.first?.id
        self.profiles = profiles
        self.addsFalseColorLUT = defaults?.object(forKey: "lut.addsFalseColor") as? Bool ?? true
        self.testMode = defaults?.bool(forKey: Self.testModeKey) ?? false
        self.haLowSeen = defaults?.bool(forKey: Self.haLowSeenKey) ?? false
        if let data = defaults?.data(forKey: "lut.names"),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            self.lutNames = names
        }
        for camera in cameras {
            let controller = makeController(camera, initialState: initialStates[camera.slot.id] ?? CameraState())
            self.cameras.append(controller)
            saved[camera.slot.id] = camera
            wire(controller)
            startIfAllowed(controller)
        }
        watchUSB()
        // Load and apply any saved HaLow settings.
        if let data = defaults?.data(forKey: Self.haLowSettingsKey),
           let saved = try? JSONDecoder().decode(HaLowSettings.self, from: data) {
            saved.migrateLegacyPasswords(in: credentials)
            self.haLowSettings = saved
        }
        startHaLow()
    }

    /// Demo cameras get the mock; real ones report that this build can't reach them.
    public static func demoOnlyBackend(_ camera: SavedCamera, password: String?) -> any CameraBackend {
        switch camera.connection {
        case .demo(let body): MockCameraBackend(body: body, label: camera.slot.label)
        case .sony: UnavailableBackend(reason: "This build has no Sony network support")
        case .blackmagic: UnavailableBackend(reason: "This build has no Blackmagic network support")
        case .blackmagicBluetooth: UnavailableBackend(reason: "This build has no Bluetooth camera support")
        case .venice: UnavailableBackend(reason: "This build has no VENICE support")
        case .arri: UnavailableBackend(reason: "This build has no ARRI support")
        }
    }

    // MARK: Pages

    public var currentPage: CameraPage? {
        pages.first { $0.id == currentPageID } ?? pages.first
    }

    /// Cameras on the current page, in page order.
    public var visibleCameras: [CameraController] {
        guard let page = currentPage else { return cameras }
        return cameras(on: page)
    }

    public func cameras(on page: CameraPage) -> [CameraController] {
        if let layout = page.layout {
            return layout.cameraIDs.compactMap { id in cameras.first { $0.id == id } }
        }
        if page.showsAllCameras { return cameras }
        // Automatic pages follow the global camera order, so reordering cameras reorders every page.
        return cameras.filter { page.cameraIDs.contains($0.id) }
    }

    /// Reorders cameras (Settings' camera list). Automatic pages follow this order.
    public func moveCameras(fromOffsets source: IndexSet, toOffset destination: Int) {
        cameras.moveElements(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorders the page tabs.
    public func movePages(fromOffsets source: IndexSet, toOffset destination: Int) {
        pages.moveElements(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Moves a page tab one step left (-1) or right (+1).
    public func movePage(_ id: UUID, by offset: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), pages.count - 1)
        guard target != index else { return }
        pages.swapAt(index, target)
        save()
    }

    public func camera(_ id: UUID) -> CameraController? {
        cameras.first { $0.id == id }
    }

    public func selectPage(_ id: UUID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        currentPageID = id
        save()
    }

    /// "A+B" style name from the cameras' labels.
    public func autoName(for cameraIDs: [UUID]) -> String {
        let labels = cameraIDs.compactMap { id in cameras.first { $0.id == id }?.slot.label }
        return labels.isEmpty ? "Empty" : labels.joined(separator: "+")
    }

    @discardableResult
    public func addPage(name: String? = nil, cameraIDs: [UUID], showsAllCameras: Bool = false) -> CameraPage {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let page = CameraPage(
            name: trimmed.isEmpty ? (showsAllCameras ? "All" : autoName(for: cameraIDs)) : trimmed,
            cameraIDs: cameraIDs,
            showsAllCameras: showsAllCameras
        )
        pages.append(page)
        currentPageID = page.id
        save()
        return page
    }

    public func setPageScrolls(_ id: UUID, _ scrolls: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        if pages[index].isScrolling != scrolls { recordUndo(index) }
        pages[index].scrolls = scrolls ? true : nil
        save()
    }

    public func updatePage(_ id: UUID, name: String, cameraIDs: [UUID], showsAllCameras: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let wanted = showsAllCameras ? cameras.map(\.id) : cameraIDs
        pages[index].name = trimmed.isEmpty ? (showsAllCameras ? "All" : autoName(for: wanted)) : trimmed
        pages[index].cameraIDs = cameraIDs
        pages[index].showsAllCameras = showsAllCameras
        // A customized page keeps its arrangement: dropped cameras lose their tiles, new ones get a block
        // underneath.
        if var layout = pages[index].layout {
            let current = Set(layout.cameraIDs)
            layout.widgets.removeAll { !wanted.contains($0.cameraID) }
            for camera in wanted where !current.contains(camera) {
                layout = LayoutTemplates.appendingBlock(for: camera, to: layout)
            }
            pages[index].layout = layout
        }
        save()
    }

    // MARK: Layout editing

    /// Starts customizing a page. An automatic page becomes an explicit copy of what it shows right now.
    public func materializeLayout(_ pageID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }), pages[index].layout == nil else { return }
        pages[index].layout = automaticLayout(index)
        save()
    }

    /// Starts customizing one camera's iPhone arrangement: a copy of what the phone shows right now (the page's
    /// customized layout re-flowed, or the camera's automatic column).
    public func materializePhoneLayout(_ pageID: UUID, camera cameraID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }), pages[index].phoneLayouts?[cameraID] == nil
        else { return }
        setLayout(index, .phone(cameraID), automaticPhoneLayout(index, camera: cameraID))
        save()
    }

    /// Ends a customization. A layout that matches the current automatic arrangement goes back to automatic,
    /// so it keeps following the built-in templates as they improve.
    public func finishEditing(_ pageID: UUID) {
        editUndo = []
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        var changed = false
        // iPhone layouts first: what the phone shows automatically depends on the page's layout.
        for (cameraID, phone) in pages[index].phoneLayouts ?? [:]
        where phone.sameArrangement(as: automaticPhoneLayout(index, camera: cameraID)) {
            setLayout(index, .phone(cameraID), nil)
            changed = true
        }
        if let layout = pages[index].layout, layout.sameArrangement(as: automaticLayout(index)) {
            pages[index].layout = nil
            changed = true
        }
        if changed { save() }
    }

    /// What an automatic page shows, as an explicit layout.
    private func automaticLayout(_ index: Int) -> PageLayout {
        LayoutTemplates.materialize(cameraIDs: cameras(on: pages[index]).map(\.id), profile: { self.camera($0)?.templateProfile })
    }

    /// What a phone shows for one camera when it has no iPhone layout: the camera's column, changed where the page was.
    private func automaticPhoneLayout(_ index: Int, camera cameraID: UUID) -> PageLayout {
        LayoutTemplates.phone(camera: cameraID, profile: camera(cameraID)?.profile, page: pages[index].layout)
    }

    /// What an iPhone shows for a camera on a page: its own arrangement if it has one, else the automatic column.
    public func phoneLayout(_ pageID: UUID, camera cameraID: UUID) -> PageLayout {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            return LayoutTemplates.phone(camera: cameraID, profile: camera(cameraID)?.profile, page: nil)
        }
        return pages[index].phoneLayouts?[cameraID] ?? automaticPhoneLayout(index, camera: cameraID)
    }

    private func layout(_ index: Int, _ target: LayoutTarget) -> PageLayout? {
        switch target {
        case .page: pages[index].layout
        case .phone(let cameraID): pages[index].phoneLayouts?[cameraID]
        }
    }

    private func setLayout(_ index: Int, _ target: LayoutTarget, _ layout: PageLayout?) {
        switch target {
        case .page:
            pages[index].layout = layout
        case .phone(let cameraID):
            var layouts = pages[index].phoneLayouts ?? [:]
            layouts[cameraID] = layout
            pages[index].phoneLayouts = layouts.isEmpty ? nil : layouts
        }
    }

    /// Moves or resizes a tile. Returns false (and changes nothing) if it would overlap another tile or
    /// leave the grid.
    @discardableResult
    public func placeWidget(_ pageID: UUID, _ widget: PageWidget, in target: LayoutTarget = .page) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              var layout = layout(index, target),
              let slot = layout.widgets.firstIndex(where: { $0.id == widget.id }),
              layout.fits(widget)
        else { return false }
        recordUndo(index)
        layout.widgets[slot] = widget
        setLayout(index, target, layout)
        save()
        return true
    }

    /// Moves a tile in edit mode, the tiles in its way swapping into its place or moving down to make room
    /// (`PageLayout.moving`); no tile changes size. Returns false if nothing moved.
    @discardableResult
    public func moveWidget(_ pageID: UUID, _ widgetID: UUID, to spot: GridSpot, in target: LayoutTarget = .page) -> Bool {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              let layout = layout(index, target),
              let moved = layout.moving(widgetID, to: spot), moved != layout
        else { return false }
        recordUndo(index)
        setLayout(index, target, moved)
        save()
        return true
    }

    /// Removes a tile. Portrait and landscape show the same tiles, so it leaves the other arrangement too: the same id
    /// where it was added to both, otherwise (arrangements made before they were linked) one tile of the same kind for
    /// the same camera. Removing on the iPhone makes an automatic page explicit, so landscape and iPad lose it as well.
    public func removeWidget(_ pageID: UUID, _ widgetID: UUID, in target: LayoutTarget = .page) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              let removed = layout(index, target)?.widgets.first(where: { $0.id == widgetID }) else { return }
        recordUndo(index)
        var targets: [LayoutTarget] = [target]
        switch target {
        case .page:
            if pages[index].phoneLayouts?[removed.cameraID] != nil { targets.append(.phone(removed.cameraID)) }
        case .phone:
            if pages[index].layout == nil { pages[index].layout = automaticLayout(index) }
            targets.append(.page)
        }
        for other in targets {
            guard var layout = layout(index, other),
                  let slot = layout.widgets.firstIndex(where: { $0.id == widgetID })
                    ?? (other == target ? nil : layout.widgets.firstIndex {
                        $0.kind == removed.kind && $0.cameraID == removed.cameraID
                    })
            else { continue }
            layout.widgets.remove(at: slot)
            setLayout(index, other, layout)
        }
        save()
    }

    /// Adds a tile at the first free spot. On an iPhone arrangement it always belongs to that camera.
    ///
    /// Portrait and landscape show the same tiles, each arranged its own way. The tile goes into the page layout
    /// (made explicit if it was automatic, so landscape and iPad also get it) and into that camera's iPhone
    /// arrangement if it has one, under the same id. Without an iPhone arrangement the phone re-flows the page.
    public func addWidget(_ pageID: UUID, kind: WidgetKind, cameraID: UUID, in target: LayoutTarget = .page) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }), layout(index, target) != nil else { return }
        recordUndo(index)
        let owner: UUID
        if case .phone(let phoneCamera) = target { owner = phoneCamera } else { owner = cameraID }
        if pages[index].layout == nil { pages[index].layout = automaticLayout(index) }
        var targets: [LayoutTarget] = [.page]
        if pages[index].phoneLayouts?[owner] != nil { targets.append(.phone(owner)) }
        let id = UUID()
        // A monitoring switch starts on the output it's for: Clean Feed on SDI, the rest on every output. A camera that
        // isn't connected goes by its demo, which has the outputs it had.
        let monitoring = camera(owner).flatMap { $0.state.monitoring ?? previewController(for: $0)?.state.monitoring }
        let output = monitoring?.defaultOutput(for: kind)
        for other in targets {
            guard var layout = layout(index, other) else { continue }
            var size = other == .page ? kind.defaultSize : LayoutTemplates.phoneSize(kind)
            let width = min(size.w, layout.columns)
            // Live View comes in at its picture's 16:9 on the grid being edited, not a strip with a postage stamp in it.
            if kind == .liveView, let grid = editedGrid, grid.pageID == pageID, grid.target == other {
                size.h = grid.cell.halfRows(forPictureAcross: width)
            }
            // On a page, in the camera's own columns where it has some and the tile fits across them: on a page of two
            // cameras side by side a tile for A never lands in a gap among B's (nor, on a phone on its side, out of view).
            let span = other == .page ? layout.columnSpan(of: owner) : nil
            let spot = span.map { layout.firstFreeSpot(w: width, h: size.h, in: $0) } ?? layout.firstFreeSpot(w: width, h: size.h)
            layout.widgets.append(PageWidget(id: id, kind: kind, cameraID: owner, x: spot.x, y: spot.y, w: width, h: size.h,
                                             output: output))
            setLayout(index, other, layout)
        }
        addedWidgetID = id
        save()
    }

    /// Sets which output a monitoring tile switches (nil: every output). Portrait and landscape show the same tile, so
    /// it changes wherever the tile is, under its id: in the page's layout (made explicit if it was automatic, as any
    /// edit on the iPhone makes it) and in its camera's iPhone arrangement.
    public func setWidgetOutput(_ pageID: UUID, _ widgetID: UUID, output: TileOutput?, in target: LayoutTarget = .page) {
        setWidgetOutputs(pageID, widgetID, outputs: output.map { [$0] } ?? [], in: target)
    }

    /// Sets the outputs a monitoring tile switches: none for every output, one, or several together.
    public func setWidgetOutputs(_ pageID: UUID, _ widgetID: UUID, outputs chosen: [TileOutput],
                                 in target: LayoutTarget = .page) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              let edited = layout(index, target)?.widgets.first(where: { $0.id == widgetID }),
              edited.kind.takesOutput else { return }
        recordUndo(index)
        if pages[index].layout == nil { pages[index].layout = automaticLayout(index) }
        var targets: [LayoutTarget] = [.page]
        if pages[index].phoneLayouts?[edited.cameraID] != nil { targets.append(.phone(edited.cameraID)) }
        for other in targets {
            guard var layout = layout(index, other),
                  let slot = layout.widgets.firstIndex(where: { $0.id == widgetID }) else { continue }
            layout.widgets[slot].setTargets(chosen)
            setLayout(index, other, layout)
        }
        save()
    }

    /// Switches the ND tile's step buttons (`PageWidget.showsStep`), wherever the tile is: in the page's layout (made
    /// explicit if it was automatic) and in its camera's iPhone arrangement, as `setWidgetOutputs` does.
    public func setWidgetStep(_ pageID: UUID, _ widgetID: UUID, on: Bool, in target: LayoutTarget = .page) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              let edited = layout(index, target)?.widgets.first(where: { $0.id == widgetID }),
              edited.kind.takesStep else { return }
        recordUndo(index)
        if pages[index].layout == nil { pages[index].layout = automaticLayout(index) }
        var targets: [LayoutTarget] = [.page]
        if pages[index].phoneLayouts?[edited.cameraID] != nil { targets.append(.phone(edited.cameraID)) }
        for other in targets {
            guard var layout = layout(index, other),
                  let slot = layout.widgets.firstIndex(where: { $0.id == widgetID }) else { continue }
            layout.widgets[slot].showsStep = on
            setLayout(index, other, layout)
        }
        save()
    }

    // MARK: Undo while editing

    /// The page being edited as it was before each edit, newest last: one swap can move several tiles,
    /// so one tap puts them back. Emptied when editing starts and when it ends. Not saved.
    public private(set) var editUndo: [CameraPage] = []
    static let editUndoLimit = 50

    /// Edit mode opens: nothing to undo yet. (Making an automatic page explicit to edit it isn't an edit.)
    public func beginEditing(_ pageID: UUID) {
        editUndo = []
    }

    /// Puts the page back as it was before its last edit.
    public func undoEdit() {
        guard let previous = editUndo.popLast(), let index = pages.firstIndex(where: { $0.id == previous.id }) else { return }
        pages[index] = previous
        save()
    }

    private func recordUndo(_ index: Int) {
        editUndo.append(pages[index])
        if editUndo.count > Self.editUndoLimit { editUndo.removeFirst(editUndo.count - Self.editUndoLimit) }
    }

    /// The tile Add Tile placed last, so the page scrolls it into view. Not saved.
    public private(set) var addedWidgetID: UUID?

    /// The grid in edit mode as it's drawn, so Add Tile can make a Live View tile the picture's shape. Not saved.
    @ObservationIgnored public var editedGrid: (pageID: UUID, target: LayoutTarget, cell: GridCellShape)?

    /// Edit mode's stand-ins for cameras that aren't connected (`previewController(for:)`), by camera. Not saved.
    @ObservationIgnored var previews: [UUID: CameraPreview] = [:]

    public func setWidgetCamera(_ pageID: UUID, _ widgetID: UUID, cameraID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }),
              let slot = pages[index].layout?.widgets.firstIndex(where: { $0.id == widgetID }) else { return }
        recordUndo(index)
        pages[index].layout?.widgets[slot].cameraID = cameraID
        save()
    }

    /// Gives every tile of one camera on a page to another, in one go: a page laid out for a demo camera, or for a camera
    /// since swapped out, goes to the real one. The first camera's iPhone arrangement goes with its
    /// tiles where the other hasn't one of its own, and the page lists the other camera in its place.
    public func moveTiles(_ pageID: UUID, from: UUID, to: UUID) {
        guard from != to, let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        recordUndo(index)
        if pages[index].layout == nil { pages[index].layout = automaticLayout(index) }
        guard var layout = pages[index].layout else { return }
        for slot in layout.widgets.indices where layout.widgets[slot].cameraID == from { layout.widgets[slot].cameraID = to }
        pages[index].layout = layout
        if var phones = pages[index].phoneLayouts, let phone = phones.removeValue(forKey: from) {
            if phones[to] == nil {
                phones[to] = PageLayout(columns: phone.columns,
                                        widgets: phone.widgets.map { var tile = $0; tile.cameraID = to; return tile })
            }
            pages[index].phoneLayouts = phones.isEmpty ? nil : phones
        }
        // An automatic page shows the cameras it lists: the other camera now, once.
        var listed: [UUID] = []
        for camera in pages[index].cameraIDs.map({ $0 == from ? to : $0 }) where !listed.contains(camera) { listed.append(camera) }
        pages[index].cameraIDs = listed
        save()
    }

    /// Back to the automatic arrangement: the whole page, or one camera's iPhone arrangement.
    public func resetLayout(_ pageID: UUID, in target: LayoutTarget = .page) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        switch target {
        case .page:
            guard let layout = pages[index].layout else { return }
            if !pages[index].showsAllCameras { pages[index].cameraIDs = layout.cameraIDs }
            pages[index].layout = nil
        case .phone:
            setLayout(index, target, nil)
        }
        save()
    }

    /// Removes a page. The last page can't be removed.
    public func removePage(_ id: UUID) {
        guard pages.count > 1 else { return }
        pages.removeAll { $0.id == id }
        if currentPageID == id { currentPageID = pages.first?.id }
        save()
    }

    // MARK: Cameras

    public func savedCamera(_ id: UUID) -> SavedCamera? { saved[id] }

    /// First unused letter, A–Z.
    public func nextFreeLabel() -> String {
        let used = Set(cameras.map(\.slot.label))
        return (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap(UnicodeScalar.init)
            .map { String($0) }
            .first { !used.contains($0) } ?? "Z"
    }

    public func nextFreeColor() -> SlotColor {
        let used = Set(cameras.map(\.slot.color))
        return SlotColor.allCases.first { !used.contains($0) } ?? .red
    }

    /// Adds a camera. It joins the current page and every "all cameras" page. On a customized page it gets
    /// a block of tiles below the existing ones.
    @discardableResult
    public func addCamera(label: String, color: SlotColor, customColor: AppearanceSettings.RGB? = nil, host: String,
                          connection: CameraConnection, password: String? = nil) -> CameraController {
        let camera = SavedCamera(slot: CameraSlot(label: label, color: color, customColor: customColor, host: host), connection: connection)
        credentials.setPassword(password, for: camera.slot.id)
        let controller = makeController(camera)
        cameras.append(controller)
        saved[camera.slot.id] = camera
        let currentID = currentPage?.id
        for index in pages.indices where pages[index].showsAllCameras || pages[index].id == currentID {
            if let layout = pages[index].layout {
                pages[index].layout = LayoutTemplates.appendingBlock(for: camera.slot.id, to: layout)
            } else if !pages[index].showsAllCameras {
                pages[index].cameraIDs.append(camera.slot.id)
            }
        }
        startIfAllowed(controller)
        watchUSB()
        save()
        return controller
    }

    @discardableResult
    public func addCamera(label: String, color: SlotColor, customColor: AppearanceSettings.RGB? = nil, host: String,
                          demoBody: MockBody) -> CameraController {
        addCamera(label: label, color: color, customColor: customColor, host: host, connection: .demo(demoBody))
    }

    /// Edits a camera. Anything that affects the connection (address, connection type, credentials)
    /// rebuilds the controller so it reconnects. `password: nil` leaves the stored password alone.
    /// `customColor`: nil leaves the camera's picked color alone, `.some(nil)` goes back to `color`.
    public func updateCamera(_ id: UUID, label: String, color: SlotColor, customColor: AppearanceSettings.RGB?? = nil, host: String,
                             connection: CameraConnection, password: String? = nil) {
        guard let index = cameras.firstIndex(where: { $0.id == id }), var camera = saved[id] else { return }
        let passwordChanged = password != nil && password != credentials.password(for: id)
        let reconnect = camera.slot.host != host || camera.connection != connection || passwordChanged
        if let password { credentials.setPassword(password, for: id) }
        if connection.sony?.usesAccessAuthentication == false { credentials.setPassword(nil, for: id) }
        camera.slot.label = label
        camera.slot.color = color
        if let customColor { camera.slot.customColor = customColor }
        camera.slot.host = host
        camera.connection = connection
        saved[id] = camera
        if reconnect {
            rebuild(at: index, camera)
        } else {
            cameras[index].slot = camera.slot
        }
        save()
    }

    /// Real cameras handed over by the installer, so a camera is set up without typing its credentials on the
    /// phone. JSON: `{"cameras": [{"label", "host", "color"?, "username"?, "password"?, "fingerprint"?}]}`.
    /// A camera with the same letter becomes this one (its pages keep working, e.g. the demo C becomes the real
    /// FX3); otherwise it's added. The password goes to the credential store. Returns how many were set up.
    @discardableResult
    public func importSeed(_ data: Data) -> Int {
        struct Seed: Decodable {
            struct Camera: Decodable {
                var label: String
                var host: String
                var color: SlotColor?
                var username: String?
                var password: String?
                var fingerprint: String?
            }
            var cameras: [Camera]
        }
        guard let seed = try? JSONDecoder().decode(Seed.self, from: data) else { return 0 }
        for entry in seed.cameras {
            let connection = CameraConnection.sony(SonyConnection(username: entry.username, trustedFingerprint: entry.fingerprint))
            if let existing = cameras.first(where: { $0.slot.label == entry.label }) {
                updateCamera(existing.id, label: entry.label, color: entry.color ?? existing.slot.color, host: entry.host,
                             connection: connection, password: entry.password)
            } else {
                addCamera(label: entry.label, color: entry.color ?? .yellow, host: entry.host, connection: connection,
                          password: entry.password)
            }
        }
        return seed.cameras.count
    }

    public func updateCamera(_ id: UUID, label: String, color: SlotColor, customColor: AppearanceSettings.RGB?? = nil, host: String,
                             demoBody: MockBody) {
        updateCamera(id, label: label, color: color, customColor: customColor, host: host, connection: .demo(demoBody))
    }

    /// The user accepted a changed fingerprint (e.g. after resetting the camera): save it and reconnect.
    public func trustFingerprint(_ fingerprint: String, for id: UUID) {
        guard let index = cameras.firstIndex(where: { $0.id == id }), var camera = saved[id] else { return }
        switch camera.connection {
        case .sony(var sony):
            sony.trustedFingerprint = fingerprint
            camera.connection = .sony(sony)
        case .blackmagic(var bm):
            bm.pinnedCertificateFingerprint = fingerprint
            camera.connection = .blackmagic(bm)
        default:
            return
        }
        saved[id] = camera
        rebuild(at: index, camera)
        save()
    }

    /// Leaves a camera with a changed fingerprint disconnected.
    public func rejectFingerprint(for id: UUID) {
        camera(id)?.disconnect()
    }

    private func rebuild(at index: Int, _ camera: SavedCamera) {
        cameras[index].disconnect()
        let controller = makeController(camera)
        cameras[index] = controller
        startIfAllowed(controller)
        watchUSB()
    }

    /// With a camera on USB: one that's plugged back in reconnects at once. A Blackmagic camera's arrivals are watched
    /// only with one saved, as on iPhone and iPad that browses the local network.
    private func watchUSB() {
        let onUSB = cameras.filter { USBCameraAddress.serial(in: $0.slot.host) != nil }
        guard startsCameras, !onUSB.isEmpty else { return }
        if usbArrivals == nil {
            usbArrivals = USBCameraArrivals { [weak self] host in
                self?.cameras.first { $0.slot.host == host }?.reconnectNow()
            }
        }
        let blackmagic = onUSB.contains { camera in
            if case .blackmagic? = saved[camera.slot.id]?.connection { return true }
            return false
        }
        usbArrivals?.start(blackmagic: blackmagic)
    }

    private func makeController(_ saved: SavedCamera, initialState: CameraState = CameraState()) -> CameraController {
        let controller = CameraController(
            slot: saved.slot,
            backend: makeBackend(saved, credentials.password(for: saved.slot.id)),
            initialState: initialState,
            lastSeen: saved.lastSeen
        )
        controller.isDemo = saved.connection.demoBody != nil
        controller.liveViewSettings = saved.liveView ?? LiveViewSettings()
        wire(controller)
        return controller
    }

    private func wire(_ controller: CameraController) {
        let id = controller.id
        controller.haLowAvailable = haLowSeen
        controller.onProfileChanged = { [weak self] profile in
            guard let self, self.saved[id] != nil else { return }
            self.saved[id]?.lastSeen = profile
            self.save()
        }
        controller.onLiveViewSettingsChanged = { [weak self] settings in
            guard let self, self.saved[id] != nil else { return }
            self.saved[id]?.liveView = settings == LiveViewSettings() ? nil : settings
            self.save()
        }
        controller.onFingerprintObserved = { [weak self] fingerprint in
            self?.rememberFingerprint(fingerprint, for: id)
        }
        controller.onStateUpdated = { [weak self] updated in
            self?.checkFX3AutoPage(for: updated)
            self?.addFalseColorLUTIfMissing(updated)
            self?.noteConnectionChange(updated)
        }
        controller.onCommand = { [weak self] command in
            self?.fanOut(command, from: id)
        }
    }

    /// Link groups: a linked command sent from one camera on the current page goes to every other camera on
    /// that page too. Values are absolute (same Kelvin, same frame rate, same shutter); REC is "make it
    /// record / make it stop" on each camera, and each camera confirms its own REC.
    func fanOut(_ command: CameraCommand, from id: UUID) {
        guard let kind = LinkKind(command) else { return }
        for peer in linkedPeers(of: id, for: kind) { peer.sendLocally(command) }
    }

    /// The cameras a `kind` command from camera `id` goes to as well: the others on the current page, while the page
    /// links that control. A tile asks before a change that restarts any of them (a VENICE's project rate).
    public func linkedPeers(of id: UUID, for kind: LinkKind) -> [CameraController] {
        guard let page = currentPage, page.isLinking, page.links.contains(kind) else { return [] }
        let onPage = cameras(on: page)
        guard onPage.contains(where: { $0.id == id }) else { return [] }
        return onPage.filter { $0.id != id }
    }

    /// Chooses which controls link on a page (they only link while linking is switched on).
    public func setLink(_ kind: LinkKind, enabled: Bool, on pageID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        var links = pages[index].links
        if enabled { links.insert(kind) } else { links.remove(kind) }
        pages[index].linkedControls = links
        save()
    }

    /// Turns linking on or off for a page without forgetting which controls are linked.
    public func setLinking(_ on: Bool, on pageID: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].linkingOn = on
        save()
    }

    /// Trust on first use: the first fingerprint a camera presents is saved without asking. Setup stays
    /// address + user + password; only a later *change* stops the connection and asks the user.
    /// Handles both Sony SSH host keys and Blackmagic TLS certificate fingerprints.
    public func rememberFingerprint(_ fingerprint: String, for id: UUID) {
        guard var camera = saved[id] else { return }
        switch camera.connection {
        case .sony(var sony) where sony.trustedFingerprint == nil:
            sony.trustedFingerprint = fingerprint
            camera.connection = .sony(sony)
        case .blackmagic(var bm) where bm.pinnedCertificateFingerprint == nil:
            bm.pinnedCertificateFingerprint = fingerprint
            camera.connection = .blackmagic(bm)
        default:
            return
        }
        saved[id] = camera
        save()
    }

    public func removeCamera(_ id: UUID) {
        guard let index = cameras.firstIndex(where: { $0.id == id }) else { return }
        cameras[index].disconnect()
        cameras.remove(at: index)
        saved[id] = nil
        credentials.setPassword(nil, for: id)
        for page in pages.indices {
            pages[page].cameraIDs.removeAll { $0 == id }
            pages[page].layout?.widgets.removeAll { $0.cameraID == id }
        }
        save()
    }

    // MARK: Camera Profile CRUD

    /// Adds a profile to the library.
    @discardableResult
    public func addProfile(_ profile: CameraProfileRecord, password: String? = nil) -> CameraProfileRecord {
        credentials.setProfilePassword(password, for: profile.id)
        profiles.append(profile)
        save()
        return profile
    }

    /// Replaces a profile in-place. Pass `password: nil` to leave the stored password unchanged.
    public func updateProfile(_ id: UUID, with updated: CameraProfileRecord, password: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if updated.cameraType != .sony || !updated.useAccessAuthentication {
            credentials.setProfilePassword(nil, for: id)   // no login any more: don't keep the old secret
        } else if let password {
            credentials.setProfilePassword(password, for: id)
        }
        profiles[index] = updated
        save()
    }

    /// Removes a profile and its stored password.
    public func removeProfile(_ id: UUID) {
        credentials.setProfilePassword(nil, for: id)
        profiles.removeAll { $0.id == id }
        save()
    }

    /// Reorders profiles (Settings list).
    public func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.moveElements(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Creates a `CameraProfileRecord` from an existing camera. The profile gets the camera's
    /// type, address, connection parameters, and current label/color; the camera's name defaults
    /// to its last-reported model name, falling back to its label. Fingerprints are not copied.
    @discardableResult
    public func saveAsProfile(from id: UUID, name: String) -> CameraProfileRecord? {
        guard let camera = saved[id] else { return nil }
        let profileType: ProfileCameraType
        let useAccessAuth: Bool
        let username: String?
        let useHTTPS: Bool
        var remoteControl: Bool?
        switch camera.connection {
        case .sony(let sony):
            profileType = .sony
            useAccessAuth = sony.usesAccessAuthentication
            username = sony.username
            useHTTPS = false
        case .blackmagic(let bm):
            profileType = .blackmagic
            useAccessAuth = bm.username != nil || bm.remoteControl
            username = bm.remoteControl ? nil : bm.username
            useHTTPS = bm.useHTTPS
            remoteControl = bm.remoteControl ? true : nil
        case .venice(let venice):
            profileType = .sony
            useAccessAuth = true
            username = venice.username
            useHTTPS = false
        case .arri:
            profileType = .arri
            useAccessAuth = false
            username = nil
            useHTTPS = false
        case .demo, .blackmagicBluetooth:
            return nil  // demo cameras can't be profiled, nor Bluetooth ones (their address is this device's alone)
        }
        let password = credentials.password(for: id)
        let profile = CameraProfileRecord(
            name: name,
            address: camera.slot.host,
            cameraType: profileType,
            letter: camera.slot.label,
            color: camera.slot.color,
            customColor: camera.slot.customColor,
            useAccessAuthentication: useAccessAuth,
            username: username,
            useHTTPS: useHTTPS,
            remoteControl: remoteControl
        )
        return addProfile(profile, password: password)
    }

    // MARK: HaLow monitor

    /// The monitor reports after every poll pass; it polls only while the app is in front (suspendAll/resumeAll).
    private func startHaLow() {
        let settings = haLowSettings
        let update: @Sendable ([HaLowNode]) -> Void = { [weak self] nodes in
            Task { @MainActor in
                guard let self, !self.haLowPreviewing else { return }
                self.haLowNodes = nodes
            }
        }
        withHaLowMonitor { monitor in
            await monitor.setOnChange(update)
            await monitor.apply(settings)
            await monitor.setForeground(true)  // starts it: polling, and looking for nodes once there's a password
        }
    }

    private func applyHaLowSettings() {
        let settings = haLowSettings
        withHaLowMonitor { await $0.apply(settings) }
    }

    /// Hands the monitor one change at a time, in order, so settings changed in quick succession land as made.
    private func withHaLowMonitor(_ operation: @escaping @Sendable (HaLowMonitor) async -> Void) {
        guard !haLowPreviewing else { return }
        let monitor = haLowMonitor, previous = haLowQueue
        haLowQueue = Task { await previous?.value; await operation(monitor) }
    }

    /// Whether the nodes' password is saved (the password itself stays in the Keychain).
    public var hasHaLowPassword: Bool { credentials.password(for: haLowPasswordID)?.isEmpty == false }

    /// Saves (nil: removes) the one password every node is logged into with, then tries it.
    public func setHaLowPassword(_ password: String?) {
        credentials.setPassword(password?.isEmpty == true ? nil : password, for: haLowPasswordID)
        withHaLowMonitor { await $0.passwordChanged() }
    }

    /// Settings → HaLow Nodes is open: look for nodes now, password or not, so it can list what's there.
    public func findHaLowNodes() {
        guard !haLowPreviewing else { return }
        let monitor = haLowMonitor
        Task { await monitor.findNodes() }
    }

    private func saveHaLowSettings() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(haLowSettings) {
            defaults.set(data, forKey: Self.haLowSettingsKey)
        }
    }

    // MARK: Persistence

    private func save() {
        guard let defaults else { return }
        let snapshot = Snapshot(
            cameras: cameras.compactMap { saved[$0.id] },
            pages: pages,
            currentPageID: currentPageID,
            profiles: profiles
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// The saved setup, or the four-camera demo lineup on first launch.
    public static func load(
        from defaults: UserDefaults = .standard,
        startCameras: Bool = true,
        holdsRealCameras: Bool = false,
        credentials: any CredentialStore = InMemoryCredentialStore(),
        makeBackend: @escaping BackendFactory = DashboardStore.demoOnlyBackend
    ) -> DashboardStore {
        if let data = defaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data).migrated() {
            return DashboardStore(
                cameras: snapshot.cameras, pages: snapshot.pages, currentPageID: snapshot.currentPageID,
                profiles: snapshot.profiles ?? [],
                defaults: defaults, startCameras: startCameras, holdsRealCameras: holdsRealCameras,
                credentials: credentials, makeBackend: makeBackend
            )
        }
        // A new install starts empty on a welcome screen: add your camera, or try a demo. It doesn't load Tiles' false
        // color LUT onto cameras until that's turned on in Settings: on someone else's camera that's a write they
        // didn't ask for. Setups from before keep it on.
        let all = CameraPage(id: UUID(), name: "All", cameraIDs: [], showsAllCameras: true)
        let store = DashboardStore(cameras: [], pages: [all], defaults: defaults, startCameras: startCameras,
                                   holdsRealCameras: holdsRealCameras, credentials: credentials, makeBackend: makeBackend)
        store.addsFalseColorLUT = false
        store.save()
        return store
    }

    /// One simulated FX3, to see what the app does without a camera. It joins the current page.
    @discardableResult
    public func addDemoCamera() -> CameraController {
        let used = Set(cameras.map(\.slot.label))
        let label = ["A", "B", "C", "D", "E", "F", "G", "H"].first { !used.contains($0) } ?? "Demo"
        return addCamera(label: label, color: .yellow, host: "demo", connection: .demo(.fx3))
    }

    /// A saved setup (the `dashboard.v1` JSON from a device) rendered with demo states, so a layout someone is
    /// looking at can be reproduced headlessly. Every camera shows as its demo body (FX3 if it isn't a demo).
    public static func preview(saved data: Data, now: Date = Date(), page pageName: String? = nil) -> DashboardStore? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data).migrated() else { return nil }
        var states: [UUID: CameraState] = [:]
        for camera in snapshot.cameras {
            states[camera.slot.id] = MockCameraBackend.sampleState(body: camera.demoBody ?? .fx3,
                                                                   label: camera.slot.label, now: now)
        }
        let current = pageName.flatMap { name in snapshot.pages.first { $0.name == name }?.id } ?? snapshot.currentPageID
        return DashboardStore(cameras: snapshot.cameras, pages: snapshot.pages, currentPageID: current,
                              profiles: snapshot.profiles ?? [], startCameras: false, initialStates: states)
    }

    /// A static, already-connected demo controller for gallery renders. No live backend.
    public static func galleryController(body: MockBody, label: String, color: SlotColor,
                                         backend: any CameraBackend, state: CameraState? = nil) -> CameraController {
        let slot = CameraSlot(label: label, color: color, host: "gallery")
        let s = state ?? MockCameraBackend.sampleState(body: body, label: label)
        let ctrl = CameraController(slot: slot, backend: backend, initialState: s)
        ctrl.isDemo = true
        return ctrl
    }

    /// Static, already-connected state for previews and headless snapshots. Camera D is recording.
    public static func preview(now: Date = Date(), page pageName: String? = nil) -> DashboardStore {
        let (cameras, pages) = demoLineup()
        var states: [UUID: CameraState] = [:]
        for camera in cameras {
            var state = MockCameraBackend.sampleState(body: camera.demoBody ?? .fx3, label: camera.slot.label, now: now)
            if camera.slot.label == "D" {
                state.recording.state = .recording
                state.takeStartedAt = now.addingTimeInterval(-83)
            }
            states[camera.slot.id] = state
        }
        let current = pageName.flatMap { name in pages.first { $0.name == name }?.id }
        return DashboardStore(
            cameras: cameras, pages: pages, currentPageID: current,
            startCameras: false, initialStates: states
        )
    }

    /// Working demo cameras of these bodies (`MockBody` case names: "venice2,venice2,fx3"), A, B, C and D on one page,
    /// held in memory: a page of several cameras of one kind for screenshots and UI checks (`-CCDebugDemoBodies`).
    /// Up to four.
    public static func demoBodies(_ names: String) -> DashboardStore {
        let colors: [SlotColor] = [.red, .blue, .yellow, .green]
        let bodies = names.split(separator: ",").compactMap { name in MockBody.allCases.first { "\($0)" == name } }
        let cameras = bodies.prefix(4).enumerated().map { index, body in
            SavedCamera(slot: CameraSlot(label: ["A", "B", "C", "D"][index], color: colors[index], host: "192.0.2.\(21 + index)"),
                        demoBody: body)
        }
        let page = CameraPage(name: cameras.map(\.slot.label).joined(separator: "+"), cameraIDs: cameras.map(\.slot.id))
        return DashboardStore(cameras: cameras, pages: [page], currentPageID: page.id)
    }

    /// Four demo cameras on documentation addresses (RFC 5737), plus pages showing all four, a pair, and a single
    /// camera. The "C" page (demo FX3) uses the FX3 template.
    public static func demoLineup() -> ([SavedCamera], [CameraPage]) {
        let cameras = [
            SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "192.0.2.21"), demoBody: .burano),
            SavedCamera(slot: CameraSlot(label: "B", color: .blue, host: "192.0.2.22"), demoBody: .fx6),
            SavedCamera(slot: CameraSlot(label: "C", color: .yellow, host: "192.0.2.23"), demoBody: .fx3),
            SavedCamera(slot: CameraSlot(label: "D", color: .green, host: "192.0.2.24"), demoBody: .fx30),
        ]
        let ids = cameras.map(\.slot.id)
        let pages = [
            CameraPage(name: "All", showsAllCameras: true),
            CameraPage(name: "A+B", cameraIDs: [ids[0], ids[1]]),
            CameraPage(name: "C", cameraIDs: [ids[2]]),  // automatic: an FX3 gets the FX3 block
        ]
        return (cameras, pages)
    }

    // MARK: - FX3 auto-page

    /// Call when a camera's state updates: if it's FX3-family and has no solo page yet, create one. Not while it's the
    /// only camera: the All page already shows exactly that, so a tester with one FX3 got two identical pages. The page
    /// comes when a second camera joins.
    public func checkFX3AutoPage(for controller: CameraController) {
        guard CameraProfile.isFX3Family(controller.state.model), cameras.count > 1,
              var camera = saved[controller.id], !camera.soloPageOffered else { return }
        // Offered once, whatever happens next: a page the user deletes stays deleted.
        camera.soloPageOffered = true
        saved[controller.id] = camera
        guard !pages.contains(where: { !$0.showsAllCameras && $0.cameraIDs == [controller.id] }) else {
            save()
            return
        }
        // An automatic page: it's drawn from the current FX3 block and what the camera reports, so it never goes
        // stale. (An explicit copy of the template froze whatever tiles the template had on the day.)
        // Named for the body: an FX30 is FX3 family (same block) but isn't an FX3.
        let name = "\(controller.slot.label) \(controller.state.modelName ?? "FX3")"
        let page = CameraPage(id: UUID(), name: name, cameraIDs: [controller.id], showsAllCameras: false)
        pages.append(page)
        save()
    }
}


extension Array {
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)` (List `.onMove`), without importing SwiftUI.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(destination - before, count)))
    }
}

// MARK: - Control API

extension DashboardStore {
    /// Starts or stops the local control server and persists the preference.
    public func setControlAPIEnabled(_ enabled: Bool, server: ControlServer) {
        if enabled {
            try? server.start()
        } else {
            server.stop()
        }
        defaults?.set(enabled, forKey: "controlAPI.enabled")
    }

    public var controlAPIEnabled: Bool {
        defaults?.bool(forKey: "controlAPI.enabled") ?? false
    }

    // MARK: False color LUT

    /// FX3 and FX3A only: other bodies have their own false color, or no use for this one.
    static func takesFalseColorLUT(model: String?) -> Bool { CameraProfile.takesFalseColorLUT(model) }

    /// Loads Tiles' false color LUT onto an FX3 that connected without one (see `addsFalseColorLUT`).
    func addFalseColorLUTIfMissing(_ camera: CameraController) {
        guard camera.state.connection == .connected else { falseColorChecked.remove(camera.id); return }
        guard addsFalseColorLUT, Self.takesFalseColorLUT(model: camera.state.model), !falseColorChecked.contains(camera.id),
              let options = camera.state.lut?.options, !options.isEmpty,
              let importer = camera.lutImporter else { return }
        falseColorChecked.insert(camera.id)
        guard !options.contains(where: isFalseColorLUT), let data = falseColorLUTData() else { return }
        Task {
            do {
                // The slot names, fresh: the picker's list can lag, and only an empty slot may be written.
                let slots = try await importer.lutSlots()
                guard !slots.contains(where: { isFalseColorLUT($0.name ?? "") }),
                      let free = slots.first(where: { ($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
                else { return }
                try await importer.importLUT(data: data, name: BundledLUT.falseColorName, slot: free.index)
            } catch {
                // Nothing to interrupt anyone with: the camera's next connection tries again.
            }
        }
    }
}
