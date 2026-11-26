import SwiftUI
import CameraCore

/// The cameras on the current page, color-coded.
///
/// Adapts to the space rather than branching per device:
/// - Pages choose the cameras. One camera, a pair, or all of them.
/// - Each camera block picks a layout from its width: the 2-wide column (four cameras on an iPad, or an
///   iPhone) or the 4-wide block (one or two cameras on an iPad or Mac).
/// - Not enough width for every camera on the page: swipe between them, with a switcher strip.
/// - Not enough height: blocks keep a usable size and scroll vertically.
public struct DashboardView: View {
    let store: DashboardStore
    /// Optional control server — when provided, the Settings sheet shows the Control API row.
    var controlServer: ControlServer?
    var controlTokenStore: ControlServerTokenStore?
    @State private var focused: UUID?
    @State private var showingSettings = false
    @State private var reportingProblem = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Terms of Use, while the store holds its cameras for them (`DashboardStore.holdsRealCameras`).
    @State private var showingTerms = false
    @State private var addingCamera = false
    @State private var pageTarget: EditorTarget?
    @State private var debugScreen: DebugScreen?
    /// Sheets opened from a tile or the edit bar, presented here at the root: attached to the tile, a sheet closed
    /// whenever the tile was rebuilt (portrait and landscape are different arrangements).
    @State private var tileSheet: TileSheet?
    @State private var isEditing = false
    @State private var confirmingReset = false
    @State private var dismissedFingerprints: Set<String> = []
    /// Phone-width (one camera at a time). Edits then go to the shown camera's iPhone arrangement.
    @State private var isCompact = false
    /// A phone on its side, on a page of several cameras: one camera at a time, each as wide as the screen
    /// (`shortPager`). Its cameras' chips go in the top bar, where the camera strip would cost rows.
    @State private var isShort = false
    /// How to move and resize tiles, over the page for a few seconds the first times a phone held upright edits: its
    /// edit bar has no room to say so.
    @State private var showingEditHint = false
    @AppStorage("editHintsShown") private var editHintsShown = 0

    /// Below this width a customized page reflows into one camera at a time (iPhone).
    static let compactWidth: CGFloat = 500
    /// Below this height (a phone on its side) a page of several cameras shows one at a time.
    static let shortHeight: CGFloat = 480

    static let narrowMinWidth: CGFloat = 250
    static let wideMinWidth: CGFloat = 480
    static let padding: CGFloat = Theme.gap * 2
    static let columnGap: CGFloat = Theme.gap * 2.5
    static let switcherHeight: CGFloat = 38
    /// The top bar and the edit bar that replaces it.
    static let barHeight: CGFloat = 40

    public init(store: DashboardStore, controlServer: ControlServer? = nil,
                controlTokenStore: ControlServerTokenStore? = nil) {
        self.store = store
        self.controlServer = controlServer
        self.controlTokenStore = controlTokenStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Edit mode swaps the top bar for the edit bar, at the same height, so the page keeps its size: no tile
            // moves or resizes on the way in or out.
            if isEditing, let page = store.currentPage {
                EditBar(store: store, page: page, phoneCamera: isCompact ? shownCamera : nil,
                        shortCamera: isShort ? shownCamera : nil, chips: chips,
                        onReset: { confirmingReset = true }, onDone: { isEditing = false })
            } else {
                TopBar(
                    store: store,
                    chips: chips,
                    onAddPage: { pageTarget = .new },
                    onEditPage: { pageTarget = .existing($0) },
                    onToggleEditing: toggleEditing,
                    onSettings: { showingSettings = true }
                )
            }
            GeometryReader { geo in
                let cameras = store.visibleCameras
                let compact = geo.size.width < Self.compactWidth
                let short = !compact && geo.size.height < Self.shortHeight && cameras.count > 1
                Group {
                    if store.cameras.isEmpty {
                        WelcomeView(onAddCamera: { addingCamera = true }, onDemo: { store.addDemoCamera() })
                    } else if compact, !cameras.isEmpty {
                        phonePager(page: store.currentPage, cameras: cameras, size: geo.size)
                    } else if short, let page = store.currentPage {
                        shortPager(page: page, cameras: cameras, size: geo.size)
                    } else if let page = store.currentPage, let layout = page.layout {
                        GridPageView(store: store, pageID: page.id, layout: layout, isEditing: isEditing,
                                     linkState: (on: page.isLinking, links: page.links))
                    } else if cameras.isEmpty {
                        EmptyPageView { if let id = store.currentPage?.id { pageTarget = .existing(id) } }
                    } else {
                        content(page: store.currentPage, cameras: cameras, size: geo.size)
                    }
                }
                .onAppear { isCompact = compact; isShort = short }
                .onChange(of: compact) { _, value in isCompact = value }
                .onChange(of: short) { _, value in isShort = value }
            }
            .overlay(alignment: .top) {
                if showingEditHint {
                    Text("Drag a tile onto another to swap them, or by its corner to resize it.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.chrome.opacity(0.94), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        // Over the tiles for a moment: not something VoiceOver should land on instead of them.
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showingEditHint)
        }
        .onChange(of: isEditing) { _, editing in
            guard editing, isCompact, editHintsShown < 2 else {
                showingEditHint = false
                return
            }
            editHintsShown += 1
            showingEditHint = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                showingEditHint = false
            }
        }
        .environment(\.controlsLocked, store.controlsLocked && !isEditing)
        // The Lock tile works the same lock as the padlock above (and the Control API's setLocked).
        .environment(\.toggleControlsLock, ToggleControlsLock { store.controlsLocked.toggle() })
        #if os(iOS)
        // Editing, a tile dragged to the top or bottom edge scrolls the page: it mustn't pull down Notification Center or
        // go home on the way (the first swipe there is the page's; a second one is the system's).
        .defersSystemGestures(on: isEditing ? .vertical : [])
        #endif
        .environment(\.lutNames, store.lutNames)
        .environment(\.presentTileSheet, PresentTileSheet { tileSheet = $0 })
        .focusedSceneValue(\.dashboardActions, DashboardActions(
            openSettings: { showingSettings = true }, reportProblem: { reportingProblem = true },
            addCamera: { addingCamera = true }, addPage: { pageTarget = .new },
            toggleEditing: toggleEditing, toggleLock: { store.controlsLocked.toggle() },
            isEditing: isEditing, isLocked: store.controlsLocked))
        // On what the tile showed: in Test Mode, an offline camera's working demo.
        .sheet(item: $tileSheet) { sheet in
            Group {
            switch sheet {
            case .liveView(let cameraID):
                if let camera = store.shownCamera(cameraID), camera.liveViewProvider != nil {
                    LiveViewSheet(camera: camera)
                }
            case .lutImport(let cameraID):
                if let camera = store.shownCamera(cameraID) { LUTImportView(camera: camera) }
            case .clipNaming(let cameraID):
                if let camera = store.shownCamera(cameraID) { ClipNamingView(camera: camera) }
            case .monitoring(let cameraID):
                if let camera = store.shownCamera(cameraID) { MonitoringView(camera: camera) }
            case .cameraMenu(let cameraID):
                if let camera = store.shownCamera(cameraID) { CameraMenuView(camera: camera) }
            case .audio(let cameraID):
                if let camera = store.shownCamera(cameraID) { AudioView(camera: camera) }
            case .assignable(let cameraID):
                if let camera = store.shownCamera(cameraID) { AssignableButtonsView(camera: camera) }
            case .afSettings(let cameraID):
                if let camera = store.shownCamera(cameraID) { AFSettingsView(camera: camera) }
            case .clips(let cameraID):
                if let camera = store.shownCamera(cameraID) { ClipListView(camera: camera) }
            case .addTile(let pageID, let phoneCameraID, let cameraID):
                AddTileSheet(store: store, pageID: pageID, phoneCameraID: phoneCameraID, startCameraID: cameraID)
            }
            }
            // Dark whatever the page's scheme: their text is the standard look's (`Theme.sheet`), and two of them set
            // no scheme of their own, which a light background would have made light.
            .preferredColorScheme(.dark)
        }
        // Tell every live-view tile whose sheet is open, so that tile pauses fetching.
        .environment(\.liveViewSheetCameraID, {
            if case .liveView(let id) = tileSheet { return id }
            return nil
        }())
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        // Dark, unless Settings → Appearance gave the page a light background: the status bar's over it.
        .preferredColorScheme(Theme.pageScheme)
        // Test Mode: a camera going live, or dropping out to its demo, is said for a moment, so the page's values never
        // change between the camera's and a demo's without a word.
        .overlay(alignment: .top) {
            if let notice = store.testModeNotice {
                TestModeNoticeView(notice: notice)
                    .padding(.top, Self.barHeight + 10)
                    .padding(.horizontal, 16)
                    // Reduce Motion: it fades in place rather than sliding down.
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation(.snappy) { store.dismissTestModeNotice(notice.id) } }
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation(.snappy) { store.dismissTestModeNotice(notice.id) }
                    }
            }
        }
        .animation(.snappy, value: store.testModeNotice)
        .sensoryFeedback(trigger: store.testModeNotice) { _, notice in notice.map { $0.isLive ? .success : .warning } }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: store, controlServer: controlServer, tokenStore: controlTokenStore)
        }
        .sheet(isPresented: $reportingProblem) {
            NavigationStack {
                ProblemReportView(store: store, controlAPIOn: controlServer?.isRunning == true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { reportingProblem = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 540, idealHeight: 640)
            #endif
        }
        .sheet(isPresented: $addingCamera) { CameraEditor(store: store, target: .new) }
        .sheet(item: $pageTarget) { PageEditor(store: store, target: $0) }
        .sheet(item: $debugScreen) { DebugScreenView(store: store, screen: $0).preferredColorScheme(.dark) }
        // Once, before any camera connects; again only for a new version. It can't be swiped away.
        .sheet(isPresented: $showingTerms) {
            TermsSheet {
                store.agreeToTerms()
                showingTerms = false
            }
        }
        .onChange(of: store.holdsRealCameras, initial: true) { _, holds in
            if holds { showingTerms = true }
        }
        .alert("Camera fingerprint changed", isPresented: Binding(get: { fingerprintPrompt != nil }, set: { _ in }), presenting: fingerprintPrompt) { prompt in
            Button("Trust New Fingerprint") { store.trustFingerprint(prompt.fingerprint, for: prompt.cameraID) }
            Button("Cancel", role: .cancel) {
                dismissedFingerprints.insert(prompt.id)
                store.rejectFingerprint(for: prompt.cameraID)
            }
        } message: { prompt in
            if prompt.isTLSCertificate {
                Text("Camera \(prompt.label) is presenting a different TLS certificate than the one saved on first connect. That's expected after regenerating the certificate in Blackmagic Camera Setup; otherwise don't trust it.\n\nNew fingerprint:\n\(prompt.fingerprint)\n\nCancel leaves it disconnected; to connect later, Edit Camera → Forget Fingerprint.")
            } else {
                Text("Camera \(prompt.label) isn't presenting the fingerprint it had before. That's expected after resetting or swapping the camera; otherwise don't trust it. The new one should match the camera's Access Authen. Info screen:\n\n\(prompt.fingerprint)\n\nCancel leaves it disconnected; to connect later, Edit Camera → Forget Fingerprint.")
            }
        }
        .confirmationDialog(isCompact ? "Reset this camera's iPhone layout?" : "Reset this page to the automatic layout?",
                            isPresented: $confirmingReset) {
            Button("Reset Layout", role: .destructive) {
                if let id = store.currentPage?.id {
                    if isCompact, let camera = shownCamera {
                        store.resetLayout(id, in: .phone(camera.id))
                    } else {
                        store.resetLayout(id)
                    }
                }
                isEditing = false
            }
        } message: {
            Text(isCompact ? "Its tile arrangement on iPhone goes back to automatic." : "Your tile arrangement for this page will be lost.")
        }
        .onChange(of: store.currentPageID) { previous, _ in
            if isEditing, let previous { store.finishEditing(previous) }
            focused = nil
            isEditing = false
        }
        // Leaving edit mode with nothing changed puts the page (or iPhone layout) back to automatic.
        .onChange(of: isEditing) { _, editing in
            if !editing, let id = store.currentPage?.id { store.finishEditing(id) }
        }
        .onChange(of: focused) {
            // Switching cameras while editing on a phone edits that camera's arrangement.
            if isEditing, isCompact, let page = store.currentPage, let camera = shownCamera {
                store.materializePhoneLayout(page.id, camera: camera.id)
            }
        }
        .onAppear {
            // Launch arguments for screenshots and UI checks: -CCDebugScreen settings, -CCDebugEditing YES.
            if let raw = UserDefaults.standard.string(forKey: "CCDebugScreen") {
                debugScreen = DebugScreen(rawValue: raw)
            }
            if UserDefaults.standard.bool(forKey: "CCDebugEditing"), !isEditing {
                // After the first layout pass, so a phone-width window knows it's compact and edits its own layout.
                DispatchQueue.main.async { toggleEditing() }
            }
            // -CCDebugLocked YES: the controls locked, to see a locked page.
            if UserDefaults.standard.bool(forKey: "CCDebugLocked") { store.controlsLocked = true }
            // -CCDebugShowTerms YES: the Terms of Use sheet over a setup held in memory (nothing is saved).
            if UserDefaults.standard.bool(forKey: "CCDebugShowTerms") { showingTerms = true }
        }
    }

    struct FingerprintPrompt: Identifiable {
        let cameraID: UUID
        let label: String
        let fingerprint: String
        /// True for Blackmagic (TLS certificate); false for Sony (SSH host key).
        let isTLSCertificate: Bool
        var id: String { cameraID.uuidString + fingerprint }
    }

    /// First camera whose fingerprint changed since it was first saved (Sony SSH or Blackmagic TLS).
    private var fingerprintPrompt: FingerprintPrompt? {
        for camera in store.cameras {
            if case .fingerprintChanged(let fingerprint) = camera.state.connection {
                let isTLS = store.savedCamera(camera.id)?.connection.blackmagic != nil
                let prompt = FingerprintPrompt(cameraID: camera.id, label: camera.slot.label,
                                               fingerprint: fingerprint, isTLSCertificate: isTLS)
                if !dismissedFingerprints.contains(prompt.id) { return prompt }
            }
        }
        return nil
    }

    /// Edit mode customizes the current page, or on a phone the shown camera's iPhone arrangement. Whatever is
    /// showing becomes an explicit copy first.
    private func toggleEditing() {
        guard let id = store.currentPage?.id else { return }
        if !isEditing {
            if isCompact, let camera = shownCamera {
                store.materializePhoneLayout(id, camera: camera.id)
            } else {
                store.materializeLayout(id)
            }
            store.beginEditing(id)
        }
        isEditing.toggle()
    }

    /// The camera a phone is showing: the focused one, or the first on the page.
    private var shownCamera: CameraController? {
        let cameras = store.visibleCameras
        return cameras.first { $0.id == focused } ?? cameras.first
    }

    /// A phone: one camera at a time, swiped between, with a switcher strip. Each camera shows its iPhone arrangement:
    /// its own if it has one, else its automatic column (`DashboardStore.phoneLayout`). Editing works on the shown
    /// camera only, without the pager, so dragging tiles can't swipe.
    @ViewBuilder
    private func phonePager(page: CameraPage?, cameras: [CameraController], size: CGSize) -> some View {
        VStack(spacing: 0) {
            if cameras.count > 1 {
                CameraSwitcher(cameras: cameras, focused: $focused)
                    .frame(height: Self.switcherHeight)
                    .padding([.horizontal, .top], Self.padding)
            }
            if isEditing, let camera = shownCamera {
                phoneCamera(page: page, camera: camera)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(cameras) { camera in
                                phoneCamera(page: page, camera: camera)
                                    .frame(width: size.width)
                                    // The HStack builds every camera; only the one scrolled into view may stream live view.
                                    .environment(\.liveViewOnScreen, camera.id == shownCamera?.id)
                                    .id(camera.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $focused)
                    .scrollIndicators(.hidden)
                    .onAppear { showFocused(proxy) }
                }
            }
        }
    }

    @ViewBuilder
    private func phoneCamera(page: CameraPage?, camera: CameraController) -> some View {
        if let page {
            GridPageView(store: store, pageID: page.id, layout: store.phoneLayout(page.id, camera: camera.id),
                         isEditing: isEditing, linkState: (on: page.isLinking, links: page.links), target: .phone(camera.id))
        }
    }

    /// The page's cameras as chips for the top bar and the edit bar, on a phone on its side; none otherwise.
    private var chips: CameraChips? {
        let cameras = store.visibleCameras
        guard isShort, cameras.count > 1 else { return nil }
        return CameraChips(cameras: cameras, focused: $focused)
    }

    /// A phone on its side, on a page of several cameras: one camera at a time, each as wide as the screen, swiped
    /// between or picked from the chips in the top bar (`LayoutTemplates.shortScreen`: its 4-wide part of the page, or
    /// its 4-wide block changed where the page was). Side by side, four cameras left every tile a sliver. Editing works
    /// on the shown camera's part of the page, without the pager, so dragging tiles can't swipe.
    @ViewBuilder
    private func shortPager(page: CameraPage, cameras: [CameraController], size: CGSize) -> some View {
        let linkState = (on: page.isLinking, links: page.links)
        if isEditing, let camera = shownCamera {
            let shown = shortArrangement(page: page, camera: camera.id, cameras: cameras)
            // A 4-wide part of the page is edited as it's shown. A 2-wide one (three or more cameras) is edited as it is
            // on the page, rows kept readable and the page scrolled: the 4-wide block shown in use isn't the page's.
            let edited = shown.origin != nil ? shown : page.layout?.cropped(to: camera.id)
            if let edited, let origin = edited.origin {
                GridPageView(store: store, pageID: page.id, layout: edited.layout, isEditing: true,
                             linkState: linkState, origin: origin, floorRow: shown.origin == nil ? 17 : nil)
                    .id(camera.id)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(cameras) { camera in
                            GridPageView(store: store, pageID: page.id,
                                         layout: shortArrangement(page: page, camera: camera.id, cameras: cameras).layout,
                                         linkState: linkState)
                                .frame(width: size.width)
                                // Only the camera in view may stream live view.
                                .environment(\.liveViewOnScreen, camera.id == shownCamera?.id)
                                .id(camera.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $focused)
                .scrollIndicators(.hidden)
                // An iPhone with a notch or Dynamic Island, on its side, has safe areas left and right. The scroll view
                // reaches into them and starts its content inside, so the next camera showed a strip in the right one.
                .clipped()
                .onAppear { showFocused(proxy) }
            }
        }
    }

    /// A pager made again (editing ends, the phone turns) starts on its first camera, while `focused` still names the
    /// one that was showing, which the switcher and the chips then light. Scrolled back to it once the new pager is
    /// laid out.
    private func showFocused(_ proxy: ScrollViewProxy) {
        guard let id = focused, store.visibleCameras.first?.id != id else { return }
        Task { @MainActor in proxy.scrollTo(id, anchor: .leading) }
    }

    private func shortArrangement(page: CameraPage, camera: UUID, cameras: [CameraController]) -> CameraArrangement {
        LayoutTemplates.shortScreen(camera: camera, cameras: cameras.map(\.id),
                                    profile: { id in store.camera(id)?.templateProfile }, page: page.layout)
    }

    static func columnsThatFit(width: CGFloat, cameras: Int) -> Int {
        let fit = Int((width - 2 * padding + columnGap) / (narrowMinWidth + columnGap))
        return min(max(fit, 1), max(cameras, 1))
    }

    /// An automatic page. Cameras sit side by side as far as the width allows, the rest a swipe away, each in its block
    /// from `LayoutTemplates` on the same grid a customized page uses, so editing starts from what was shown: the
    /// 4-wide block (an FX3 gets its own) when a camera has the width for it, else the 2-wide column. Once a camera has
    /// reported, tiles for controls it doesn't have are left out.
    @ViewBuilder
    private func content(page: CameraPage?, cameras: [CameraController], size: CGSize) -> some View {
        let perPage = Self.columnsThatFit(width: size.width, cameras: cameras.count)
        let columnWidth = (size.width - 2 * Self.padding - CGFloat(perPage - 1) * Self.columnGap) / CGFloat(perPage)
        let wide = columnWidth >= Self.wideMinWidth
        let groups = stride(from: 0, to: cameras.count, by: perPage).map {
            Array(cameras[$0..<min($0 + perPage, cameras.count)])
        }
        let linkState = (on: page?.isLinking ?? false, links: page?.links ?? [])
        let pageID = page?.id ?? UUID()
        let grid = { (group: [CameraController]) in
            GridPageView(store: store, pageID: pageID,
                         layout: LayoutTemplates.materialize(cameraIDs: group.map(\.id), wide: wide,
                                                             profile: { id in group.first { $0.id == id }?.templateProfile }),
                         // Only where the columns line up row by row: two cameras side by side each get their own wide
                         // block, which end where they end.
                         linkState: linkState, showsHeldGaps: !wide)
        }
        if groups.count > 1 {
            VStack(spacing: 0) {
                CameraSwitcher(cameras: cameras, focused: $focused)
                    .frame(height: Self.switcherHeight)
                    .padding([.horizontal, .top], Self.padding)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(groups.indices, id: \.self) { index in
                            grid(groups[index])
                                .frame(width: size.width)
                                .id(groups[index][0].id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: groupFocus(groups))
                .scrollIndicators(.hidden)
            }
        } else {
            grid(cameras)
        }
    }

    /// The switcher focuses a camera; the wide pager scrolls by group, named after its first camera.
    private func groupFocus(_ groups: [[CameraController]]) -> Binding<UUID?> {
        Binding(
            get: { focused.flatMap { id in groups.first { $0.contains { $0.id == id } }?.first?.id } },
            set: { focused = $0 }
        )
    }
}

/// Camera chips shown when not every camera on the page fits. Tap to jump; shows who's recording.
struct CameraSwitcher: View {
    let cameras: [CameraController]
    @Binding var focused: UUID?

    var body: some View {
        HStack(spacing: Theme.gap) {
            ForEach(cameras) { camera in
                let isFocused = (focused ?? cameras.first?.id) == camera.id
                let tint = camera.slot.tint
                let recording = camera.state.recording.state == .recording
                // A camera that isn't connected says what its link is doing, in its label tile's words, in place of its
                // model: on an iPhone its page is out of view.
                let link = LabelTile.linkStatus(camera)
                Button {
                    withAnimation(.snappy) { focused = camera.id }
                } label: {
                    HStack(spacing: 6) {
                        Text(camera.slot.label)
                            .font(Theme.mono(16, weight: .heavy))
                            .foregroundStyle(Theme.legible(tint))
                        if recording {
                            Circle().fill(Theme.recording).frame(width: 7, height: 7)
                        }
                        Text(link?.text ?? camera.state.modelName ?? "—")
                            .font(Theme.mono(10, weight: .semibold))
                            .foregroundStyle(link?.color ?? Theme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(isFocused ? Theme.control : Theme.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tint.opacity(isFocused ? 1 : 0.45), lineWidth: isFocused ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Camera \(camera.slot.label)" + (camera.state.modelName.map { ", \($0)" } ?? ""))
                .accessibilityIdentifier("cameraSwitcher.\(camera.slot.label)")
                .accessibilityValue(CameraChips.spoken(showing: isFocused, recording: recording, link: link?.text))
            }
        }
    }
}

struct TopBar: View {
    let store: DashboardStore
    /// The page a Delete Page is waiting on the user's say-so for.
    @State private var deletingPage: CameraPage?
    /// The page's cameras, on a phone on its side (`DashboardView.shortPager`).
    var chips: CameraChips? = nil
    var onAddPage: () -> Void
    var onEditPage: (UUID) -> Void
    var onToggleEditing: () -> Void
    var onSettings: () -> Void

    var body: some View {
        bar
            .confirmationDialog("Delete the page \(deletingPage?.name ?? "")?",
                                isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } }),
                                titleVisibility: .visible, presenting: deletingPage) { page in
                Button("Delete Page", role: .destructive) { store.removePage(page.id) }
            } message: { _ in
                Text("Its layout goes with it. The cameras stay.")
            }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            // Page tabs scroll rather than truncate ("A…" on an iPhone with four pages), keeping the current one in view.
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
            HStack(spacing: 8) {
            ForEach(store.pages) { page in
                let selected = page.id == store.currentPage?.id
                let recording = store.cameras(on: page).contains { $0.state.recording.state == .recording }
                Button {
                    store.selectPage(page.id)
                } label: {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(Theme.recording).frame(width: 6, height: 6)
                        }
                        Text(page.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Theme.style.accentText : Theme.text)
                    .background(selected ? Theme.style.accent : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .id(page.id)
                .contextMenu {
                    Button("Edit Page…", systemImage: "pencil") { onEditPage(page.id) }
                    Section {
                        Button("Move Left", systemImage: "arrow.left") { store.movePage(page.id, by: -1) }
                            .disabled(page.id == store.pages.first?.id)
                        Button("Move Right", systemImage: "arrow.right") { store.movePage(page.id, by: 1) }
                            .disabled(page.id == store.pages.last?.id)
                    }
                    if store.pages.count > 1 {
                        // Asked first: it takes the page's own layout with it, and there's no undo.
                        Section {
                            Button("Delete Page…", systemImage: "trash", role: .destructive) { deletingPage = page }
                        }
                    }
                }
            }
            }
            }
            .scrollIndicators(.hidden)
            .onAppear { if let id = store.currentPage?.id { proxy.scrollTo(id) } }
            .onChange(of: store.currentPageID) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id) } }
            }
            }
            if let chips { chips.fixedSize() }
            // Outside the scrolling tabs, so adding a page is always one tap away.
            Button(action: onAddPage) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Test Mode is on: said where a glance at the bar catches it, and turned off from here.
            if store.testMode {
                Menu {
                    Button("Turn Off Test Mode") { store.testMode = false }
                } label: {
                    Text("TEST")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1)
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(SlotColor.yellow.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Test Mode is on")
                .accessibilityHint("Turns it off")
            }
            // Linking, for a page of two cameras or more: left of the meter, so what comes and goes moves only the things
            // left of it, and the meter, the pencil, the lock and the gear stay where a thumb expects them.
            if let page = store.currentPage, store.cameras(on: page).count >= 2 {
                LinkButton(store: store, page: page)
            }
            LinkMeter(cameras: store.currentPage.map { store.cameras(on: $0) } ?? [],
                      haLow: HaLowLink.links(store),
                      testMode: Binding(get: { store.testMode }, set: { store.testMode = $0 }))
            // A pencil, the usual sign for editing.
            BarButton(symbol: "pencil", label: "Edit Tiles", action: onToggleEditing)
            BarButton(symbol: store.controlsLocked ? "lock.fill" : "lock.open",
                      label: store.controlsLocked ? "Unlock Controls" : "Lock Controls",
                      isActive: store.controlsLocked) { store.controlsLocked.toggle() }
            BarButton(symbol: "gearshape", label: "Settings", action: onSettings)
        }
        .padding(.horizontal, 16)
        .frame(height: DashboardView.barHeight)
        .background(Theme.chrome)
        .environment(\.colorScheme, Theme.chromeScheme)
    }
}

/// How the links to this page's cameras are doing: bars from the worst round trip, colored like the latency
/// tile; no bars when a camera isn't connected. Tap for each camera's state, and why one failed; tapping a camera
/// that's down tries it again. When HaLow nodes are configured, they're listed in the menu and their signal counts
/// toward the bar quality.
struct LinkMeter: View {
    let cameras: [CameraController]
    /// HaLow nodes, when set up: their signal counts toward the bars, and they're listed under the cameras.
    var haLow: [HaLowLink] = []
    /// Test Mode, switched here too: this menu is where a camera that isn't connected shows as offline.
    var testMode: Binding<Bool>?

    var body: some View {
        let overHaLow = haLow.contains { $0.state == .polling }
        let quality = Self.combined(cameras.isEmpty ? nil : Self.quality(cameras, overHaLow: overHaLow), Self.quality(haLow))
        Menu {
            ForEach(cameras) { camera in
                Button {
                    camera.reconnectNow()
                } label: {
                    if let why = Self.down(camera) {
                        // Says what a tap does: the camera is tried again now, not at its next retry.
                        Text("Reconnect \(Self.name(camera))")
                        Text(why)
                    } else {
                        Text(Self.describe(camera))
                    }
                }
            }
            if !haLow.isEmpty {
                Section("HaLow") {
                    ForEach(haLow, id: \.self) { link in
                        Text(link.line)
                    }
                }
            }
            if let testMode {
                Section { Toggle("Test Mode", isOn: testMode) }
            }
        } label: {
            Image(systemName: "cellularbars", variableValue: quality.bars)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(quality.color)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .accessibilityLabel("Connections")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(cameras.isEmpty && haLow.isEmpty)
    }

    /// The weaker of the camera links and the HaLow link wins: the cameras are controlled through it.
    static func combined(_ cameras: (bars: Double, color: Color)?, _ haLow: (bars: Double, color: Color)?)
        -> (bars: Double, color: Color) {
        switch (cameras, haLow) {
        case let (c?, h?): c.bars <= h.bars ? c : h
        case let (c?, nil): c
        case let (nil, h?): h
        case (nil, nil): (0, Theme.secondaryText)
        }
    }

    /// Weakest listed node; a node that isn't answering (listed when HaLow is set to always show) is no bars.
    static func quality(_ haLow: [HaLowLink]) -> (bars: Double, color: Color)? {
        guard !haLow.isEmpty else { return nil }
        return haLow.map { $0.state == .polling ? HaLowSignal.quality($0.signalDBm) : (0, Theme.recording) }
            .min { $0.bars < $1.bars }
    }

    /// Worst camera wins: any camera not connected is no bars (red); otherwise the slowest round trip sets the
    /// bars, on the latency tile's scale (`LatencyGrade`: under 80 ms green, under 200 ms yellow, else red; over
    /// HaLow, when a node answers, under 300 and 600 ms).
    static func quality(_ cameras: [CameraController], overHaLow: Bool = false) -> (bars: Double, color: Color) {
        guard !cameras.isEmpty else { return (0, Theme.secondaryText) }
        guard cameras.allSatisfy({ $0.state.connection == .connected }) else { return (0, Theme.recording) }
        let worst = cameras.compactMap(\.state.latencyMilliseconds).max() ?? 0
        return LatencyGrade.grade(worst, overHaLow: overHaLow)
    }

    static func name(_ camera: CameraController) -> String {
        [camera.slot.label, camera.state.modelName].compactMap { $0 }.joined(separator: " ")
    }

    /// Why a camera that a tap reconnects is down: offline, or why its connection failed. Nil while it's up or busy.
    static func down(_ camera: CameraController) -> String? {
        switch camera.state.connection {
        case .disconnected: "Offline"
        case .failed(let reason): reason
        default: nil
        }
    }

    static func describe(_ camera: CameraController) -> String {
        let state: String = switch camera.state.connection {
        case .connected: camera.state.latencyMilliseconds.map { "\($0) ms" } ?? "connected"
        case .connecting: "connecting"
        case .awaitingApproval: BluetoothCameraAddress.id(in: camera.slot.host) == nil ? "approve on camera" : "type the camera's code"
        case .fingerprintChanged: "fingerprint changed"
        case .stale: "resyncing"
        case .disconnected: "offline"
        case .failed: "failed"
        }
        return "\(name(camera)) · \(state)"
    }
}

/// The chain in the top bar, on a page of two or more cameras: a menu that links them, and picks what follows.
struct LinkButton: View {
    let store: DashboardStore
    let page: CameraPage

    var body: some View {
        let isOn = page.isLinking
        Menu {
            Toggle("Link Cameras on This Page", isOn: Binding(get: { isOn }, set: { store.setLinking($0, on: page.id) }))
            Section("Linked Controls") {
                ForEach(LinkKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(get: { page.links.contains(kind) },
                                                     set: { store.setLink(kind, enabled: $0, on: page.id) }))
                }
            }
            // Open until a tap outside it: each tap picks or drops one control, so picking several would take
            // reopening the menu for each. A Mac's menus close on a click whatever the app asks.
            .modifier(MenuStaysOpen())
        } label: {
            Image(systemName: isOn ? "link.circle.fill" : "link.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Theme.timecode : Theme.secondaryText)
                .frame(width: 30, height: 24)
                .background(isOn ? Theme.timecode.opacity(0.18) : Theme.control,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Link Cameras")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// What the menu bar can do on the dashboard in front (`DashboardCommands`).
struct DashboardActions {
    var openSettings: () -> Void
    var reportProblem: () -> Void
    var addCamera: () -> Void
    var addPage: () -> Void
    var toggleEditing: () -> Void
    var toggleLock: () -> Void
    var isEditing: Bool
    var isLocked: Bool
}

extension FocusedValues {
    @Entry var dashboardActions: DashboardActions?
}

/// The dashboard's commands in the menu bar, with their keys: a Mac's menu bar had only the system's items (no
/// Settings, no ⌘,), and an iPad with a keyboard lists these when ⌘ is held.
public struct DashboardCommands: Commands {
    @FocusedValue(\.dashboardActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.openSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Add Camera…") { actions?.addCamera() }
                .disabled(actions == nil)
            Button("Add Page…") { actions?.addPage() }
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Report a Problem…") { actions?.reportProblem() }
                .disabled(actions == nil)
            Link("Tiles Support", destination: Support.site)
        }
        CommandMenu("Page") {
            Button(actions?.isEditing == true ? "Done Editing" : "Edit Tiles") { actions?.toggleEditing() }
                .keyboardShortcut("e")
                .disabled(actions == nil)
            Button(actions?.isLocked == true ? "Unlock Controls" : "Lock Controls") { actions?.toggleLock() }
                .keyboardShortcut("l")
                .disabled(actions == nil)
        }
    }
}

/// A menu's items that leave it open when picked (iPhone and iPad; a Mac's menus always close).
struct MenuStaysOpen: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.menuActionDismissBehavior(.disabled)
        #else
        content
        #endif
    }
}

/// Shown under the top bar while customizing a page.
struct EditBar: View {
    let store: DashboardStore
    let page: CameraPage
    @Environment(\.presentTileSheet) private var presentTileSheet
    /// Editing one camera's iPhone arrangement (phone width), or nil for the whole page.
    var phoneCamera: CameraController?
    /// The camera shown on a phone on its side, which Add Tile starts on, and the page's cameras to switch between.
    var shortCamera: CameraController? = nil
    var chips: CameraChips? = nil
    var onReset: () -> Void
    var onDone: () -> Void

    var body: some View {
        // The most that fits, on one line, never wrapped: a narrow bar wraps labels mid-word. First the title and how
        // to edit, then the title alone, then the controls alone, and on a phone Add Tile, Done and the rest in a menu.
        ViewThatFits(in: .horizontal) {
            if let note = hintText { bar(title: true, hint: note) }
            if phoneCamera == nil, let demoNote { bar(title: true, hint: demoNote) }
            bar(title: true)
            bar(title: false)
            compactBar
        }
        .padding(.horizontal, 16)
        .frame(height: DashboardView.barHeight)
        // A yellow wash over the bars' color: the page's background under it took black text to black with custom
        // colors (in Ink the two are both black).
        .background(SlotColor.yellow.color.opacity(0.12))
        .background(Theme.chrome)
        .environment(\.colorScheme, Theme.chromeScheme)
    }

    /// How to edit, and which cameras are demos of themselves because they aren't connected. Not on a phone's layout:
    /// there's no room.
    private var hintText: String? {
        guard phoneCamera == nil else { return nil }
        let howTo = "Drag onto a tile to swap · corner to resize · letter to change camera"
        return demoNote.map { "\(howTo) · \($0)" } ?? howTo
    }

    private func bar(title: Bool, hint: String? = nil) -> some View {
        HStack(spacing: 10) {
            if title {
                Text("Editing \(page.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let chips { chips.fixedSize() }
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            // Here as well as in the page's settings: it's while arranging tiles that it matters.
            Toggle(isOn: fitsToScreen) {
                Text("Fit to Screen")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            undo(labelled: true)
            addTile
            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .fixedSize()
            done
        }
    }

    /// A phone held upright: Add Tile and Done, with Fit to Screen and Reset in a menu.
    private var compactBar: some View {
        HStack(spacing: 12) {
            addTile
            undo(labelled: false)
            Spacer(minLength: 8)
            Menu {
                Toggle("Fit to Screen", isOn: fitsToScreen)
                Button(role: .destructive, action: onReset) { Label("Reset", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
            done
        }
    }

    /// One step back: a swap or a push can move several tiles (⌘Z with a keyboard).
    private func undo(labelled: Bool) -> some View {
        Button(action: store.undoEdit) {
            if labelled {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .disabled(store.editUndo.isEmpty)
        .keyboardShortcut("z", modifiers: .command)
        .accessibilityLabel("Undo")
        .fixedSize()
    }

    private var fitsToScreen: Binding<Bool> {
        Binding(get: { !page.isScrolling }, set: { store.setPageScrolls(page.id, !$0) })
    }

    // A list in a sheet, not a Menu: the menu read live camera state, so every latency tick rebuilt it while it was open
    // and snapped the scroll back to the top on a phone.
    private var addTile: some View {
        Button {
            presentTileSheet(.addTile(page: page.id, phoneCamera: phoneCamera?.id, camera: shortCamera?.id))
        } label: {
            Label("Add Tile", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .fixedSize()
    }

    /// In the look's accent, like the page tab that's selected, rather than the system's blue.
    private var done: some View {
        Button(action: onDone) {
            Text("Done")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.style.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Theme.style.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// "Camera A is offline: demo values", for the cameras on the page drawn as demos of themselves.
    private var demoNote: String? {
        let labels = store.cameras(on: page).filter { store.previewController(for: $0) != nil }.map(\.slot.label)
        guard !labels.isEmpty else { return nil }
        return labels.count == 1 ? "Camera \(labels[0]) is offline: demo values"
            : "Cameras \(labels.joined(separator: ", ")) are offline: demo values"
    }
}

struct BarButton: View {
    var symbol: String
    /// What VoiceOver (and a UI test) calls it.
    var label: String
    var isActive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.lockedText : Theme.secondaryText)
                .frame(width: 30, height: 24)
                .background(isActive ? Theme.locked : Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct EmptyPageView: View {
    var action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("No cameras on this page")
                .font(Theme.mono(16, weight: .semibold))
                .foregroundStyle(Theme.backgroundSecondaryText)
            Button("Choose Cameras…", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a new install opens on: add your camera, or try one demo camera to see the app without one.
struct WelcomeView: View {
    var onAddCamera: () -> Void
    var onDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tiles")
                .font(Theme.mono(34, weight: .heavy))
                .foregroundStyle(Theme.backgroundText)
            Text("Camera control over the network: settings and REC, sending as little data as it can.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.backgroundSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button(action: onAddCamera) {
                    Label("Add a Camera", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.style.backgroundText ?? Theme.needle)
                Button(action: onDemo) {
                    Label("Try a Demo Camera", systemImage: "camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Text("Tried on the Sony FX3, FX5, FX6, BURANO and VENICE 2, the Blackmagic PYXIS 12K and the ARRI ALEXA Mini. "
                 + "Other models are built from their makers' documents.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.backgroundSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}



// MARK: - Sheets opened from tiles

/// A sheet a tile (or the edit bar) asks the dashboard to present.
enum TileSheet: Identifiable, Hashable, Sendable {
    case liveView(UUID)
    case lutImport(UUID)
    case clipNaming(UUID)
    case monitoring(UUID)
    /// The camera's own buttons (`CameraMenuView`).
    case cameraMenu(UUID)
    /// A Blackmagic camera's audio channels (`AudioView`).
    case audio(UUID)
    /// The camera's assignable buttons (`AssignableButtonsView`).
    case assignable(UUID)
    /// A Sony body's autofocus settings (`AFSettingsView`).
    case afSettings(UUID)
    /// The camera's clips, to play one (`ClipListView`).
    case clips(UUID)
    /// `camera`: the one Add Tile starts on (the one shown, on a phone on its side), else the page's first.
    case addTile(page: UUID, phoneCamera: UUID?, camera: UUID? = nil)

    var id: Self { self }
}

/// How a tile asks for a sheet. Outside a dashboard (the gallery, previews) it does nothing.
struct PresentTileSheet: Sendable {
    var present: @MainActor @Sendable (TileSheet) -> Void = { _ in }
    @MainActor func callAsFunction(_ sheet: TileSheet) { present(sheet) }
}

private struct PresentTileSheetKey: EnvironmentKey {
    static let defaultValue = PresentTileSheet()
}

extension EnvironmentValues {
    var presentTileSheet: PresentTileSheet {
        get { self[PresentTileSheetKey.self] }
        set { self[PresentTileSheetKey.self] = newValue }
    }
}

/// Add Tile: the tiles a camera can back, as a list. The kinds are read once when the sheet opens, so live camera
/// updates don't rebuild it under your finger. Editing a whole page, a picker chooses the camera first.
/// What a tile is for, as Add Tile groups them.
enum TileGroup: CaseIterable {
    case camera, exposure, recording, monitoring, lens, other

    var title: String {
        switch self {
        case .camera: "Camera"
        case .exposure: "Exposure"
        case .recording: "Recording"
        case .monitoring: "Monitoring"
        case .lens: "Focus and Lens"
        case .other: "More"
        }
    }

    init(_ kind: WidgetKind) {
        switch kind {
        case .label, .status, .battery, .media, .timecode, .latency, .haLow, .lock, .tally, .call, .cameraMenu,
             .assignable:
            self = .camera
        case .iso, .shutterDial, .shutterValue, .frameRate, .wbPreset, .wbSliders, .iris, .ndPreset, .ndMinus, .ndPlus,
             .ndMode, .ecs, .shootingMode, .dynamicRange, .colorGamut:
            self = .exposure
        case .record, .recordAll, .codec, .bitrate, .resolution, .format, .desqueeze, .clipName, .playback, .clips, .proxy,
             .recordedLUT, .imagerMode, .audio, .grabStill:
            self = .recording
        case .lut, .look, .viewAssist, .falseColor, .zebra, .focusAssist, .frameGuides, .cleanFeed, .statusText,
             .statusTextContent, .monitoring, .colorBars, .hdmiInfo, .gridLines, .userFrameA, .userFrameB, .liveView,
             .liveViewButton, .sensorFlip:
            self = .monitoring
        case .focusMode, .autoFocus, .afSettings, .focusDrive, .zoomDrive, .steadyShot:
            self = .lens
        case .webGUI:
            self = .other
        }
    }
}

struct AddTileSheet: View {
    let store: DashboardStore
    let pageID: UUID
    /// The camera whose iPhone arrangement is being edited, or nil for the whole page.
    let phoneCameraID: UUID?
    /// The camera to start on (the one shown, on a phone on its side), else the page's first.
    var startCameraID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var choices: [Choice] = []
    @State private var cameraID: UUID?

    struct Choice: Identifiable {
        let id: UUID
        let label: String
        let kinds: [WidgetKind]
        /// Each tile's name for this camera (`WidgetKind.title(for:)`).
        let titles: [WidgetKind: String]
    }

    var body: some View {
        NavigationStack {
            List {
                if phoneCameraID == nil && choices.count > 1 {
                    Picker("Camera", selection: $cameraID) {
                        ForEach(choices) { choice in
                            Text(choice.label).tag(Optional(choice.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                }
                // In groups, as the tiles are on a page: a camera with forty-odd tiles is unreadable as one long
                // alphabetical list.
                let kinds = choices.first { $0.id == cameraID }?.kinds ?? []
                ForEach(TileGroup.allCases, id: \.self) { group in
                    let inGroup = kinds.filter { TileGroup($0) == group }
                    if !inGroup.isEmpty {
                        Section(group.title) {
                            ForEach(inGroup, id: \.self) { kind in
                                Button {
                                    guard let cameraID else { return }
                                    store.addWidget(pageID, kind: kind, cameraID: cameraID,
                                                    in: phoneCameraID.map { .phone($0) } ?? .page)
                                    dismiss()
                                } label: {
                                    Text(choices.first { $0.id == cameraID }?.titles[kind] ?? kind.title)
                                        .foregroundStyle(Theme.sheet.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Tile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 400, minHeight: 420, idealHeight: 520)
        #endif
        .onAppear(perform: snapshot)
    }

    /// Only tiles the camera can back: no adding de-squeeze to an FX3.
    private func snapshot() {
        let cameras = phoneCameraID.flatMap { id in store.camera(id).map { [$0] } } ?? store.cameras
        choices = cameras.compactMap { camera in
            let kinds = store.tileKinds(for: camera)
            // Named as the camera does, or its demo while it isn't connected ("LUT" on a Blackmagic camera's outputs).
            let shown = store.previewController(for: camera) ?? camera
            var titles = Dictionary(uniqueKeysWithValues: kinds.map { ($0, $0.title(for: shown.state)) })
            // The LUT's switch where it's every output's is "LUT" on its tile, as the LUT picker is: listed together,
            // two rows read "LUT" (an FX6's), so the switch says it's the switch.
            for kind in [WidgetKind.viewAssist, .look] where kinds.contains(kind) {
                if let title = titles[kind], titles.contains(where: { $0.key != kind && $0.value == title }) {
                    titles[kind] = "\(title) On/Off"
                }
            }
            let sorted = kinds.sorted { titles[$0]!.localizedStandardCompare(titles[$1]!) == .orderedAscending }
            return kinds.isEmpty ? nil : Choice(id: camera.id, label: "Camera \(camera.slot.label)", kinds: sorted, titles: titles)
        }
        // The page's own camera (the first on it) unless someone picks another: on a page of B's tiles, a new tile is B's.
        let onPage = store.pages.first { $0.id == pageID }.map { store.cameras(on: $0).map(\.id) } ?? []
        cameraID = cameraID ?? startCameraID.flatMap { id in choices.contains { $0.id == id } ? id : nil }
            ?? onPage.first { id in choices.contains { $0.id == id } } ?? choices.first?.id
    }
}

/// "Camera A is live", or "Camera A is offline: its demo is showing", for a moment, in Test Mode.
struct TestModeNoticeView: View {
    let notice: TestModeNotice

    var body: some View {
        let tint = notice.isLive ? Theme.timecode : Theme.legible(SlotColor.yellow.color)
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(notice.isLive ? "Camera \(notice.label) is live" : "Camera \(notice.label) is offline: its demo is showing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.chrome, in: Capsule())
        .overlay(Capsule().strokeBorder(tint, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// The page's cameras as small chips: the top bar's camera switcher on a phone on its side, where the strip under it
/// would cost rows. The one shown is filled and outlined in its color, a recording one has a red dot. Tap to show it.
struct CameraChips: View {
    let cameras: [CameraController]
    @Binding var focused: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(cameras) { camera in
                let isFocused = (focused ?? cameras.first?.id) == camera.id
                let tint = camera.slot.tint
                let recording = camera.state.recording.state == .recording
                Button {
                    withAnimation(.snappy) { focused = camera.id }
                } label: {
                    HStack(spacing: 4) {
                        Text(camera.slot.label)
                            .font(Theme.mono(13, weight: .heavy))
                            .foregroundStyle(Theme.legible(tint))
                            .lineLimit(1)
                            .fixedSize()
                        if recording {
                            Circle().fill(Theme.recording).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(minWidth: 30, minHeight: 24)
                    .background(isFocused ? Theme.control : Theme.tile, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(isFocused ? 1 : 0.35), lineWidth: isFocused ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show Camera \(camera.slot.label)")
                .accessibilityIdentifier("cameraSwitcher.\(camera.slot.label)")
                .accessibilityValue(Self.spoken(showing: isFocused, recording: recording,
                                                link: LabelTile.linkStatus(camera)?.text))
            }
        }
    }

    /// What VoiceOver says of a camera in a switcher besides its name: whether it's the one shown, rolling, and what its
    /// link is doing when it isn't connected (the red dot and the words are only seen).
    static func spoken(showing: Bool, recording: Bool, link: String?) -> String {
        [showing ? "Showing" : nil, recording ? "Recording" : nil, link].compactMap { $0 }.joined(separator: ", ")
    }
}
