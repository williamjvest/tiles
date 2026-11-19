import SwiftUI
import CameraCore

// MARK: - Playback

/// Playback controls tile. Offered in Add Tile only when the camera reports playback capability.
/// Shows a clip caption row and a row of icon buttons for the capabilities the camera actually supports.
/// Follows phone size (≥393 pt) and iPad; two-row anatomy when height permits, one-line otherwise.
struct PlaybackTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    /// The speed a scan runs at, under the arrow going that way, where the camera says (an FX6's 4×, 15×, 24×); nil
    /// while it plays at speed, pauses, or goes the other way.
    static func scanning(_ speed: Double?, forward: Bool) -> String? {
        guard let speed, abs(speed) > 1, (speed > 0) == forward else { return nil }
        return "\(Int(abs(speed).rounded()))×"
    }

    /// Two rows need the caption row over a 36 pt button.
    private static let oneLineBelow: CGFloat = 2 * Theme.insetV + Theme.captionHeight + Theme.captionGap + 36

    var body: some View {
        let pb = camera.state.playback
        let active = camera.state.connection.isControllable && pb != nil
        Tile(tint: camera.slot.tint, isEnabled: active) {
            GeometryReader { geo in
                if geo.size.height < (Self.oneLineBelow + Theme.captionRowGrowth) * s, pb?.capabilities.review == true {
                    // One line on an FX3: the Live | Review switch names the tile, and the caption's width is what
                    // lets ◀◀ ▶▶ stay beside ⏮ ⏭ on a phone. No taller than the tile: buttons taller than a short
                    // tile are cut off top and bottom.
                    // Text Size makes the switch's type bigger only where the row has the height for it.
                    // Never wider than the tile either: play and the Live | Review switch are 168 pt at 1.
                    let fit = max(1, (geo.size.width - 2 * Theme.inset * s) / Self.shortestRow(pb))
                    let text = min(s, max(1, min(geo.size.height / 36, fit)))
                    buttonRow(pb: pb, active: active, scale: min(s, geo.size.height / 36, fit), text: text)
                        .environment(\.tileScale, text)
                        .padding(.horizontal, Theme.inset * s)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    captioned(pb: pb, active: active)
                }
            }
        }
    }

    private func captioned(pb: PlaybackState?, active: Bool) -> some View {
        TileFrame(caption: "Playback", oneLineBelow: Self.oneLineBelow) { _, size in
            CentredTransport(lift: (Theme.captionRow + Theme.captionGap) * s / 2, captionGap: Theme.captionGap * s,
                             clearance: Theme.inset * s) {
                // Laid out as the standard row in the room over the Text Size scale, `s` times bigger.
                // Never wider than the tile: in a narrow one play and the Live | Review switch outgrew it.
                buttonRow(pb: pb, active: active,
                          scale: min(s * scale(for: CGSize(width: size.width / s, height: size.height / s), pb: pb),
                                     max(scale(for: size, pb: pb), size.width / Self.shortestRow(pb))),
                          text: s)
                // Measured, not drawn: the caption and the readout the buttons mustn't run into.
                Text(verbatim: "PLAYBACK").font(Theme.caption(s)).tracking(Theme.captionTracking(s)).hidden()
                Text(verbatim: pb.map(clipCaption) ?? "").font(Theme.readout(s)).hidden()
            }
        } accessory: { placement in
            if placement == .header, let pb, !clipCaption(pb).isEmpty {
                Text(clipCaption(pb))
                    .font(Theme.readout(s))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    /// Live or Review, for a camera that has to be put into playback first (the FX3): in the row, the buttons' size.
    /// No way into Review while recording (the backend refuses it too).
    /// `text`: the Text Size scale its type is drawn at (`tileScale` where it is), which the switch multiplies its
    /// segment height by too.
    private func modeSwitch(pb: PlaybackState?, active: Bool, scale: CGFloat, text: CGFloat) -> some View {
        let reviewing = pb?.inReview == true
        let canSwitch = active && (reviewing || camera.state.recording.state == .idle)
        return MiniSegmented(options: ["Live", "Review"], selection: reviewing ? "Review" : "Live", label: { $0 },
                             isEnabled: canSwitch, segmentHeight: 30 * scale / text) { mode in
            if (mode == "Review") != reviewing { send(reviewing ? .live : .review) }
        }
        .frame(width: 124 * scale)
    }

    /// The row at its shortest, at 1: play, and the Live | Review switch after its spacing and padding.
    static func shortestRow(_ pb: PlaybackState?) -> CGFloat {
        36 + (pb?.capabilities.review == true ? 4 + 4 + 124 : 0)
    }

    /// The row grows with a bigger tile, by up to a third, while all of it still fits the tile's width: on an iPad or a
    /// Mac a 36 pt row sat small in the middle of the tile.
    private func scale(for size: CGSize, pb: PlaybackState?) -> CGFloat {
        let caps = pb?.capabilities ?? PlaybackCapabilities()
        let count = CGFloat(buttons(caps, isPlaying: pb?.isPlaying).count)
        // The row as `buttonRow` lays it out: buttons and their spacing, then the switch after its spacing and padding.
        let fixed = max(count - 1, 0) * 4 + (caps.review ? 8 : 0)
        let scaled = count * 36 + (caps.review ? 124 : 0)
        let fitsWidth = (size.width - fixed) / max(scaled, 1)
        // 36 pt targets at least, unless the tile is shorter than that: then as tall as it is, rather than cut off.
        return min(max(min(size.height / 36, fitsWidth), min(1, size.height / 36)), 1.35)
    }

    // MARK: - Button row

    /// A button and how much it's worth keeping when the tile is narrow (0 = always).
    private struct PlaybackButton: Identifiable {
        let id: String
        let priority: Int
        let command: PlaybackCommand
    }

    private func buttons(_ caps: PlaybackCapabilities, isPlaying: Bool?) -> [PlaybackButton] {
        var b: [PlaybackButton] = []
        // A narrow tile keeps clip changes (priority 1) before scanning (2).
        // A camera that doesn't say whether it's playing gets the plain toggle, not a guess.
        let playIcon = isPlaying == nil && caps.review ? "playpause.fill" : isPlaying == true ? "pause.fill" : "play.fill"
        if caps.nextPrevious { b.append(.init(id: "backward.end.fill", priority: 1, command: .previous)) }
        if caps.fastForwardRewind { b.append(.init(id: "backward.fill", priority: 2, command: .rewind)) }
        if caps.seek {
            b.append(.init(id: "gobackward.15", priority: 3, command: .skip(-15)))
            b.append(.init(id: "gobackward.5", priority: 2, command: .skip(-5)))
        }
        if caps.playPause { b.append(.init(id: playIcon, priority: 0, command: .togglePlay)) }
        if caps.seek {
            b.append(.init(id: "goforward.5", priority: 2, command: .skip(5)))
            b.append(.init(id: "goforward.15", priority: 3, command: .skip(15)))
        }
        if caps.fastForwardRewind { b.append(.init(id: "forward.fill", priority: 2, command: .fastForward)) }
        if caps.nextPrevious { b.append(.init(id: "forward.end.fill", priority: 1, command: .next)) }
        if caps.stop { b.append(.init(id: "stop.fill", priority: 4, command: .stop)) }
        // Rec Review plays the last take back: a replay symbol, not ↩, which reads as Back.
        if caps.recReview { b.append(.init(id: "memories", priority: 4, command: .recReview)) }
        return b
    }

    /// The buttons the camera has, dropping the least essential first when the tile is too narrow for all of them
    /// (a quarter-width phone tile still gets previous, play and next) rather than clipping them at the edge.
    @ViewBuilder
    private func buttonRow(pb: PlaybackState?, active: Bool, scale: CGFloat, text: CGFloat) -> some View {
        let caps = pb?.capabilities ?? PlaybackCapabilities()
        let all = buttons(caps, isPlaying: pb?.isPlaying)
        // A camera that has to be put into review first only takes the transport buttons while it's there. Locked,
        // `Tile` takes the taps and grays the row, as it does every control's.
        let transport = active && (!caps.review || pb?.inReview == true)
        ViewThatFits(in: .horizontal) {
            ForEach([4, 3, 2, 1, 0], id: \.self) { keep in
                HStack(spacing: 4) {
                    ForEach(all.filter { $0.priority <= keep }) { button in
                        if caps.review, button.command == .fastForward || button.command == .rewind {
                            let forward = button.command == .fastForward
                            ScanButton(systemImage: button.id, forward: forward, enabled: transport,
                                       speed: caps.scanSpeedLabel ?? Self.scanning(camera.state.playback?.speed, forward: forward),
                                       scale: scale, send: send)
                        } else if button.command == .recReview {
                            // Rec Review plays the last take from the live picture, so it's live's, not review's.
                            pbButton(button.id, enabled: active && pb?.inReview != true, scale: scale) { send(button.command) }
                        } else {
                            pbButton(button.id, enabled: transport, scale: scale) { send(button.command) }
                        }
                    }
                    if caps.review { modeSwitch(pb: pb, active: active, scale: scale, text: text).padding(.leading, 4 * text) }
                    // A Live button only where there's no Live | Review switch to be it (an ARRI had both).
                    if caps.live && !caps.review && keep >= 1 {
                        PillToggle(title: "Live", lit: nil, isEnabled: active, height: 26) { send(.live) }
                            .fixedSize()
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: - Helpers

    private func pbButton(_ systemImage: String, enabled: Bool, scale: CGFloat, action: @escaping () -> Void) -> some View {
        // 36 pt targets at least: these get hit with a thumb, on a phone, on set.
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Theme.symbol(16 * scale))
                .foregroundStyle(enabled ? Theme.text : Theme.secondaryText.opacity(0.5))
                .frame(width: 36 * scale, height: 36 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func send(_ cmd: PlaybackCommand) {
        camera.send(.playback(cmd))
    }

    private func clipCaption(_ pb: PlaybackState) -> String {
        var parts: [String] = []
        if let name = pb.clipName { parts.append(name) }
        if let n = pb.clipNumber, let total = pb.clipCount { parts.append("\(n) of \(total)") }
        // The camera's list ends before the latest take: what's playing is older (Play on the camera shows it).
        if pb.latestTakeMissing { parts.append("not the latest take") }
        if let position = pb.position, let duration = pb.duration {
            parts.append("\(Self.clock(position)) / \(Self.clock(duration))")
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Playback's buttons, centered in the whole tile where that clears the caption and the clip readout at its top
/// (in a wide tile, centering in the content room leaves space either side). Where centered would
/// run into either, they're centered in the room under the caption row, as every captioned tile's content is. It's laid
/// out in that room (`TileFrame`'s), with the buttons first and then the caption and the readout, hidden, to measure.
private struct CentredTransport: Layout {
    /// From the room's middle up to the tile's: half the caption row and the gap under it.
    var lift: CGFloat
    /// From the room's top up to the caption row's bottom.
    var captionGap: CGFloat
    /// Kept between the buttons and the caption or the readout beside them.
    var clearance: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let row = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height))
        let caption = subviews[1].sizeThatFits(.unspecified).width
        let readout = subviews[2].sizeThatFits(.unspecified).width
        let x = bounds.midX - row.width / 2
        let inRoom = bounds.midY - row.height / 2
        let centred = inRoom - lift
        let clears = centred >= bounds.minY - captionGap
            || (x - bounds.minX >= caption + clearance && bounds.maxX - (x + row.width) >= readout + clearance)
        subviews[0].place(at: CGPoint(x: x, y: clears ? centred : inRoom), proposal: ProposedViewSize(row))
        subviews[1].place(at: bounds.origin, proposal: .unspecified)
        subviews[2].place(at: bounds.origin, proposal: .unspecified)
    }
}

/// ◀◀ / ▶▶ on a camera played through its own buttons (the FX3): moves within the clip. Tapped, it skips a few seconds;
/// held, it scans until let go, then plays on. A clip that isn't playing starts first. Where the camera's speed is
/// known (a VENICE's 4×), it's written under the arrows, and the arrows stay on the row's line.
private struct ScanButton: View {
    let systemImage: String
    let forward: Bool
    let enabled: Bool
    var speed: String?
    var scale: CGFloat = 1
    let send: (PlaybackCommand) -> Void
    @GestureState private var touching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var scanning = false

    var body: some View {
        // The arrows are drawn as every other button's symbol is, 16 pt in the middle of the square, so ◀◀ ▶▶ sit on
        // the same line as ⏮ ▶ ⏭ (stacked with the speed, they rode above it). The speed is laid over the
        // square's bottom, under the arrows, so it never moves them.
        Image(systemName: systemImage)
            .font(Theme.symbol(16 * scale))
            .frame(width: 36 * scale, height: 36 * scale)
            .overlay(alignment: .bottom) {
                if let speed {
                    // The button's own size, whatever Text Size says: it has a 36 pt square to share with the arrows.
                    // Its letters have no descenders, so 1.5 pt down puts them on the square's bottom edge, 3 pt
                    // under the arrows rather than 1.5 (measured on a 2× render).
                    Text(verbatim: speed)
                        .font(Theme.caption(Theme.textScale(scale, shortLine: true)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .offset(y: 1.5 * scale)
                }
            }
            .foregroundStyle(enabled ? Theme.text : Theme.secondaryText.opacity(0.5))
            .opacity(touching && enabled ? 0.5 : 1)
            .contentShape(Rectangle())
            // One gesture for tap and hold, so a hold never also counts as a tap. `touching` resets even when the
            // gesture is canceled (the iPhone pager taking a swipe that started here), so a scan always ends.
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if Self.moved(value) { holdTask?.cancel() }   // a swipe, not a press
                }
                .onEnded { value in
                    holdTask?.cancel()
                    if enabled, !scanning, !Self.moved(value) { send(forward ? .fastForward : .rewind) }
                })
            .onChange(of: touching) { _, now in
                holdTask?.cancel()
                holdTask = nil
                if now, enabled {
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        scanning = true
                        send(.scan(forward: forward))
                    }
                } else if !now, scanning {
                    scanning = false
                    send(.endScan)
                }
            }
            .accessibilityElement()
            .accessibilityLabel((forward ? "Fast forward" : "Rewind") + (speed.map { " at \($0)" } ?? ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { send(forward ? .fastForward : .rewind) } }
    }

    /// Far enough that the finger is swiping, not pressing.
    private static func moved(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > 12 || abs(value.translation.height) > 12
    }
}
