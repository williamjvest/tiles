import SwiftUI
import ImageIO
import CameraCore

// MARK: - Live View

/// Live view tile, two kinds:
/// • Live View (`showsPicture`): the picture in the tile, aspect-fit. Tap opens LiveViewSheet.
/// • Live View Button: just opens LiveViewSheet; zero data until then.
///
/// **Data rule (strict):** frames are pulled only while ALL conditions hold:
///   1. The tile is on the *current* page (not merely on-screen in a neighboring page in a paged container).
///   2. The scene is `.active`.
///   3. The camera is connected and hasLiveView.
///   4. No full LiveViewSheet for this camera is open (the sheet takes over; parallel fetches are suppressed).
/// Any condition failing → unsubscribe immediately → zero requests → camera's live view stopped.
///
/// One stream per camera: the tile and the sheet share a `LiveViewSession` on `CameraController`;
/// the session is reference-counted and never fetches without a subscriber.
struct LiveViewTile: View {
    let camera: CameraController
    /// Store for page-membership gate. Nil in gallery/previews → always uses launcher mode.
    let store: DashboardStore?
    /// The picture in the tile; false for Live View Button.
    var showsPicture = true

    @Environment(\.presentTileSheet) private var presentTileSheet
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.liveViewOnScreen) private var liveViewOnScreen
    @Environment(\.tileScale) private var s

    /// ID of the camera whose full LiveViewSheet is currently open, or nil.
    @Environment(\.liveViewSheetCameraID) private var sheetCameraID

    /// True when the sheet is open for *this* camera.
    private var sheetOpen: Bool { sheetCameraID == camera.id }

    /// Latest frame received from the session (nil = no frame yet / not streaming).
    @State private var frame: Image? = nil
    @State private var meter = FrameRateMeter()
    @State private var isStreaming = false
    /// Stable delegate object bridging the session callback → @MainActor state.
    @State private var delegate = LiveViewDelegate()
    /// Decoded once on appear; reused every body pass so the JPEG is not decoded per-render.
    @State private var previewFrame: Image? = nil

    /// Previews and the snapshot gallery have no camera to stream from: they show this frame instead. Nothing is fetched.
    nonisolated(unsafe) static var previewJPEG: Data?
    private var previewing: Bool { store == nil && Self.previewJPEG != nil }

    var body: some View {
        let available = camera.state.hasLiveView && camera.state.connection == .connected
        // The picture is a monitor and stays bright while the controls are locked; the button is a control.
        Tile(tint: camera.slot.tint, isEnabled: available, isReadout: showsPicture) {
            GeometryReader { geo in
                let showInline = showsPicture
                Button {
                    guard available else { return }
                    presentTileSheet(.liveView(camera.id))
                } label: {
                    if showInline {
                        inlinePicture(available: available)
                    } else {
                        launcherLabel(available: available)
                    }
                }
                .buttonStyle(.plain)
                .onChange(of: shouldStream(showInline: showInline, available: available)) { _, active in
                    if active { subscribe() } else { unsubscribe() }
                }
                .onAppear {
                    // Decode the preview JPEG once so body reads a cached Image, not raw bytes.
                    if previewFrame == nil, let jpeg = Self.previewJPEG {
                        previewFrame = makeSwiftUIImage(from: jpeg)
                    }
                    delegate.onFrame = { image, _ in
                        frame = image
                        meter.frameArrived()
                        isStreaming = true
                    }
                    delegate.onError = { _ in isStreaming = false }
                    if shouldStream(showInline: showInline, available: available) { subscribe() }
                }
                .onDisappear { unsubscribe() }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func inlinePicture(available: Bool) -> some View {
        ZStack {
            if let img = frame ?? (previewing ? previewFrame : nil) {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The last frame stays when the stream stops (page flipped, app away, camera gone), dimmed so a
                    // still picture never passes for a live one.
                    .opacity(isStreaming || previewing ? 1 : 0.4)
                // Live indicator — bottom-leading, unobtrusive
                if isStreaming || previewing {
                    liveIndicator
                }
            } else {
                launcherLabel(available: available)
            }
        }
        .contentShape(Rectangle())
    }

    private func launcherLabel(available: Bool) -> some View {
        GeometryReader { geo in
            let icon = Image(systemName: "video.fill")
                .font(Theme.symbol(18 * s))
                .foregroundStyle(available ? Theme.strong : Theme.secondaryText)
            // Icon over caption where they fit (about 40 pt), beside it in a shorter tile.
            Group {
                if geo.size.height >= 40 * s {
                    VStack(spacing: 4 * s) { icon; Caption("Live View") }
                } else {
                    HStack(spacing: 6 * s) { icon; Caption("Live View") }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .contentShape(Rectangle())
    }

    private var liveIndicator: some View {
        HStack(spacing: 3 * s) {
            Circle().fill(Theme.recording).frame(width: 5 * s, height: 5 * s)
            Text(meter.text.map { "LIVE · \($0)" } ?? "LIVE")
                .font(Theme.caption(s))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 5 * s)
        .padding(.vertical, 2 * s)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(5 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Visibility gate

    /// All five conditions: inline mode, scene active, camera live, on current page, no sheet open.
    private func shouldStream(showInline: Bool, available: Bool) -> Bool {
        showInline
            && available
            && scenePhase == .active
            && isOnCurrentPage
            && !sheetOpen
    }

    /// The containers decide this, not onAppear: GridPageView clears it unless its page is the current one, and the
    /// iPhone pager clears it for every camera but the one in view (its HStack builds them all, so their tiles all
    /// appear). Without a store (gallery, previews) nothing streams.
    private var isOnCurrentPage: Bool { store != nil && liveViewOnScreen }

    // MARK: - Session management

    private func subscribe() {
        guard let session = camera.liveViewSession else { return }
        Task { await session.subscribe(delegate) }
    }

    private func unsubscribe() {
        isStreaming = false
        meter = FrameRateMeter()
        guard let session = camera.liveViewSession else { return }
        Task { await session.unsubscribe(delegate) }
    }
}

#if os(macOS)
/// The Mac's Live View window, full screen as it opens. The app declares it as a WindowGroup with this id and a camera
/// ID; the Live View sheet's full-screen button opens it.
public struct LiveViewWindow: View {
    public static let id = "live-view"
    let camera: CameraController

    public init(camera: CameraController) { self.camera = camera }

    public var body: some View {
        LiveViewSheet(camera: camera, inWindow: true)
            .background(FullScreenOnAppear())
    }
}

/// Puts the window it's in into full screen once it's there.
private struct FullScreenOnAppear: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}
#endif

/// Previews and the snapshot gallery: the frame an inline Live View tile shows when there's no camera to stream from.
public enum LiveViewTilePreview {
    @MainActor public static var jpeg: Data? {
        get { LiveViewTile.previewJPEG }
        set { LiveViewTile.previewJPEG = newValue }
    }
}

// MARK: - LiveViewSessionDelegate bridge

/// Bridges `LiveViewSessionDelegate` callbacks to `@MainActor` state for both the tile and the sheet.
@MainActor
final class LiveViewDelegate: LiveViewSessionDelegate, @unchecked Sendable {
    /// The frame and its size in pixels.
    var onFrame: (@MainActor (Image?, CGSize?) -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    nonisolated func liveViewSession(_ session: LiveViewSession, didReceive frame: LiveViewFrame) {
        // Decoded here, off the main actor: a camera on a cable sends 24 frames a second, and decoding each one
        // while drawing it would load the main thread.
        let image = frame.image ?? frame.jpeg.flatMap(Self.decode)
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
        Task { @MainActor [weak self] in self?.onFrame?(image.map { Image(decorative: $0, scale: 1) }, size) }
    }

    private nonisolated static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    nonisolated func liveViewSession(_ session: LiveViewSession, didFail error: Error) {
        Task { @MainActor [weak self] in self?.onError?(error) }
    }
}

// MARK: - LiveView sheet camera environment key

/// The camera ID whose LiveViewSheet is currently open, or nil if no sheet is open.
private struct LiveViewSheetCameraKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// ID of the camera whose full LiveViewSheet is open. The inline tile for that camera reads this
    /// to pause fetching while the sheet holds the stream.
    var liveViewSheetCameraID: UUID? {
        get { self[LiveViewSheetCameraKey.self] }
        set { self[LiveViewSheetCameraKey.self] = newValue }
    }

}

/// False when a tile's container is built but not shown: a page that isn't the current one, or a camera the iPhone
/// pager has scrolled past. An inline Live View tile only pulls frames while this is true.
private struct LiveViewOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var liveViewOnScreen: Bool {
        get { self[LiveViewOnScreenKey.self] }
        set { self[LiveViewOnScreenKey.self] = newValue }
    }
}

/// The sheet that shows live frames with their frame rate, the quality menu, and auto-stop logic.
/// Subscribes to the camera's shared `LiveViewSession` on appear; the tile on the same camera pauses while open.
struct LiveViewSheet: View {
    let camera: CameraController
    /// The Mac's own Live View window (a sheet can't go full screen there): the picture fills it.
    var inWindow = false

    init(camera: CameraController, inWindow: Bool = false) {
        self.camera = camera
        self.inWindow = inWindow
        _isFullscreen = State(initialValue: inWindow)
    }

    private var slotColor: Color { camera.slot.tint }
    private var cameraLabel: String { camera.slot.label }

    @State private var frame: Image? = nil
    @State private var meter = FrameRateMeter()
    /// The frames' size in pixels, as the camera sends them.
    @State private var pictureSize: CGSize?
    /// What the link picks when nothing has been chosen: where the quality menu starts.
    @State private var linkConfig = LiveViewConfig()
    @State private var isStreaming = false
    @State private var timedOut = false
    @State private var error: String? = nil
    @State private var deadlineTask: Task<Void, Never>? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private let config = LiveViewConfig()

    /// Picture edge-to-edge on black, the stream carrying on: on iPhone and iPad it covers the whole app (on iPad a
    /// sheet is a card in the middle, and filling only that wasn't full screen); on the Mac it fills the sheet.
    @State private var isFullscreen = false
    @State private var delegate = LiveViewDelegate()

    var body: some View {
        // A navigation bar with a standard Done, like the app's other sheets: the old closer was small gray text at
        // the bottom and easy to miss.
        NavigationStack {
            ZStack {
                (isFullscreen ? Color.black : Theme.sheet.background).ignoresSafeArea()
                #if os(macOS)
                if isFullscreen { fullscreenView } else { windowed }
                #else
                windowed
                #endif
            }
            .navigationTitle(cameraLabel.isEmpty ? "Live View" : "Live View · \(cameraLabel)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .fullScreenCover(isPresented: $isFullscreen) {
            fullscreenView
                .background(Color.black.ignoresSafeArea())
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .preferredColorScheme(.dark)
        }
        #endif
        .onAppear { startStream() }
        .task { if let provider = camera.liveViewProvider { linkConfig = await provider.liveViewConfig } }
        // Full screen covering the sheet isn't the sheet going away.
        .onDisappear { if !isFullscreen { stopStream() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopStream() }
        }
    }

    private var windowed: some View {
        VStack(spacing: 16) {
            frameView
                .overlay(alignment: .bottomTrailing) { fullscreenButton(entering: true).padding(8) }
            statsRow
            if timedOut {
                keepWatchingButton
            } else if let err = error {
                errorText(err)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    /// Fullscreen: the frame fills the screen at its own aspect, with the camera, frame rate and the way out over it.
    private var fullscreenView: some View {
        ZStack {
            if let img = frame {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(Theme.sheet.secondaryText)
            }
            if timedOut {
                keepWatchingButton
            } else if let err = error {
                errorText(err)
            }
        }
        .overlay(alignment: .topTrailing) { fullscreenButton(entering: false).padding(12) }
        .overlay(alignment: .bottomLeading) {
            Text([cameraLabel.isEmpty ? nil : cameraLabel, meter.text].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.readout)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(12)
        }
    }

    private func fullscreenButton(entering: Bool) -> some View {
        Button {
            #if os(macOS)
            // Full screen is the Live View window's: from the sheet, open it and close the sheet; in it, close it.
            if entering { openWindow(id: LiveViewWindow.id, value: camera.id) }
            dismiss()
            #else
            withAnimation(.easeInOut(duration: 0.2)) { isFullscreen = entering }
            #endif
        } label: {
            Image(systemName: entering ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(Theme.symbol(15))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entering ? "Full screen" : "Exit full screen")
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(Theme.readout)
            .foregroundStyle(Theme.recording)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var frameView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .strokeBorder(slotColor, lineWidth: 1.5)
            if let img = frame {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    if isStreaming {
                        ProgressView()
                            .tint(Theme.sheet.secondaryText)
                        Text("Fetching first frame…")
                            .font(Theme.readout)
                            .foregroundStyle(Theme.sheet.secondaryText)
                    } else {
                        Image(systemName: "video.slash")
                            .font(Theme.symbol(24, weight: .regular))
                            .foregroundStyle(Theme.sheet.secondaryText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
    }

    /// Frame rate and picture size as they arrive, and the menu that changes them.
    private var statsRow: some View {
        HStack {
            Text([meter.text, pictureSize.map { "\(Int($0.width))×\(Int($0.height))" }].compactMap { $0 }
                .joined(separator: " · "))
                .font(Theme.readout)
                .foregroundStyle(Theme.sheet.secondaryText)
            Spacer()
            qualityMenu
        }
    }

    /// Picture quality and frame rate for this camera: the link's own choice until one is picked. Saved with the
    /// camera; the tile on the dashboard streams the same way.
    private var qualityMenu: some View {
        let chosen = camera.liveViewSettings.applied(to: linkConfig)
        return Menu {
            Picker("Picture", selection: Binding(get: { chosen.quality },
                                                 set: { camera.liveViewSettings.quality = $0 })) {
                Text("High").tag(LiveViewQuality.high)
                Text("Low").tag(LiveViewQuality.low)
            }
            .pickerStyle(.inline)
            // A stream (Blackmagic) comes at the camera's own frame rate: no choice to offer.
            if !linkConfig.isStream {
                Picker("Frame Rate", selection: Binding(get: { (1 / chosen.frameInterval).rounded() },
                                                        set: { camera.liveViewSettings.framesPerSecond = $0 })) {
                    ForEach(LiveViewSettings.frameRates, id: \.self) { Text("\(Int($0)) fps").tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Quality", systemImage: "slider.horizontal.3")
                .font(Theme.readout)
                .foregroundStyle(Theme.sheet.text)
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var keepWatchingButton: some View {
        Button {
            timedOut = false
            startStream()
        } label: {
            Text("Keep Watching")
                .font(Theme.buttonLabel())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(slotColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func startStream() {
        guard !isStreaming else { return }
        guard let session = camera.liveViewSession else { return }
        isStreaming = true
        timedOut = false
        error = nil
        meter = FrameRateMeter()

        delegate.onFrame = { [self] image, size in
            frame = image
            pictureSize = size
            meter.frameArrived()
            error = nil
        }
        delegate.onError = { [self] err in
            // Playback stops a Blackmagic camera's stream, and it starts again in live: not an error to report.
            if case LiveViewError.noData = err, camera.state.playback?.inReview == true {
                self.error = "Live view comes back when the camera leaves playback"
            } else {
                // Live view's own errors say what happened and what to do (an FX5's "turn on MENU → Network →
                // Stream → Setting"); anything else is the link, said plainly rather than in Apple's error prose.
                self.error = (err as? LiveViewError)?.errorDescription
                    ?? "Live view stopped: no answer from the camera. Check its connection."
            }
            isStreaming = false
        }

        Task { await session.subscribe(delegate) }

        // Auto-stop after the link's interval (none on a cable).
        let provider = camera.liveViewProvider
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor in
            guard let autoStop = await provider?.liveViewConfig.autoStopSeconds ?? config.autoStopSeconds else { return }
            try? await Task.sleep(for: .seconds(autoStop))
            guard !Task.isCancelled else { return }
            timedOut = true
            stopStream()
        }
    }

    private func stopStream() {
        deadlineTask?.cancel()
        deadlineTask = nil
        isStreaming = false
        guard let session = camera.liveViewSession else { return }
        Task { await session.unsubscribe(delegate) }
    }
}

// MARK: - Platform helpers

/// Live view's frames a second, from when the last frames arrived (up to 30 of them, over at most 3 s).
struct FrameRateMeter {
    private var arrivals: [Date] = []

    mutating func frameArrived(at now: Date = Date()) {
        arrivals.append(now)
        arrivals.removeAll { now.timeIntervalSince($0) > 3 }
        if arrivals.count > 31 { arrivals.removeFirst(arrivals.count - 31) }
    }

    var framesPerSecond: Double? {
        guard arrivals.count > 1, let first = arrivals.first, let last = arrivals.last, last > first else { return nil }
        return Double(arrivals.count - 1) / last.timeIntervalSince(first)
    }

    /// "24 fps"; below 2, to a tenth ("0.5 fps"). nil until two frames have come.
    var text: String? {
        framesPerSecond.map { $0 < 2 ? String(format: "%.1f fps", $0) : "\(Int($0.rounded())) fps" }
    }
}

// MARK: - Platform image helper

#if canImport(UIKit)
import UIKit
@MainActor
private func makeSwiftUIImage(from data: Data) -> Image? {
    UIImage(data: data).map { Image(uiImage: $0) }
}
#elseif canImport(AppKit)
import AppKit
@MainActor
private func makeSwiftUIImage(from data: Data) -> Image? {
    NSImage(data: data).map { Image(nsImage: $0) }
}
#endif
