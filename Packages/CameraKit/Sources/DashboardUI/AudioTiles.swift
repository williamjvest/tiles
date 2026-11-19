import SwiftUI
import CameraCore

/// Autofocus. A push, where the camera has one: a Blackmagic camera with a lens it can focus (the middle of the picture),
/// an FX5's Push Auto Focus. Where its AF / MF reads as well (an FX5), that's beside the caption, so continuous autofocus
/// is switched on here too, and the push grays while the camera is
/// focusing by itself. The AF / MF tile is the switch alone, for a camera with no push (an FX3, FX6, BURANO). The push is
/// a button, not a switch: the camera doesn't say what it found, so the tile lights for a moment to say the tap went, as
/// a toggle lights while it's on.
struct AutoFocusTile: View {
    let camera: CameraController
    @State private var lit = false
    @Environment(\.tileScale) private var s

    var body: some View {
        let state = camera.state
        let controllable = state.connection.isControllable
        let push = controllable && state.canPushAutoFocus
        Group {
            if let mode = state.focusMode {
                Tile(tint: camera.slot.tint, fill: lit ? Theme.engaged : Theme.tile, isEnabled: true) {
                    // "Focus": "Autofocus" was cut to "AUTOFO…" beside AF | MF in a phone's column. On one line the push
                    // wins over the caption (it's what the tile is for).
                    TileFrame(caption: "Focus", valueWins: true) { oneLine, size in
                        pushButton("Push AF", enabled: push, short: oneLine || size.height < 34 * s, inset: 0)
                    } accessory: { _ in
                        let live = controllable && mode.isWritable
                        // Short of room for both, a chip that says which and switches to the other, as the ISO tile's base.
                        ViewThatFits(in: .horizontal) {
                            MiniSegmented(options: mode.options, selection: mode.shown, label: { $0 }, isEnabled: live,
                                          small: true) {
                                camera.send(.setFocusMode($0))
                            }
                            PillToggle(title: mode.shown, lit: nil, isEnabled: live) {
                                let i = mode.options.firstIndex(of: mode.shown).map { $0 + 1 } ?? 0
                                if mode.options.count > 1 { camera.send(.setFocusMode(mode.options[i % mode.options.count])) }
                            }
                            .fixedSize()
                        }
                    }
                }
            } else {
                // One-shot only (a Blackmagic camera's): the tile is the button.
                Tile(tint: camera.slot.tint, fill: lit ? Theme.engaged : Theme.tile, isEnabled: state.canAutoFocus) {
                    GeometryReader { geo in
                        pushButton("Autofocus", enabled: push, short: geo.size.height < 34 * s, inset: Theme.inset * s)
                    }
                }
            }
        }
        .task(id: lit) {
            guard lit else { return }
            try? await Task.sleep(for: .milliseconds(600))
            lit = false
        }
    }

    private func pushButton(_ title: String, enabled: Bool, short: Bool, inset: CGFloat) -> some View {
        Button {
            camera.send(.autoFocus)
            lit = true
        } label: {
            Text(title)
                .font(Theme.buttonLabel(short: short, scale: s))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(enabled ? Theme.text : Theme.secondaryText)
                .padding(.horizontal, inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHint(camera.state.canAutoFocus && !camera.state.canPushAutoFocus ? "Autofocus is on: switch to MF to push it"
                           : camera.state.make == .blackmagic ? "Focuses on the middle of the picture"
                           : "Focuses once, then focus stays manual")
    }
}

/// The camera's audio. A Blackmagic camera's channels (`CameraState.audioChannels`): each one's gain, and a tap opens
/// the rest (`AudioView`: its input, gain, phantom power, low cut and pad). A VENICE's meters (`AudioMetersTile`), which
/// only show: the network reads its sound and sets none of it.
struct AudioTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet
    @Environment(\.tileScale) private var s

    var body: some View {
        let channels = camera.state.audioChannels
        if channels.isEmpty && camera.state.audioMeterCount > 0 {
            AudioMetersTile(camera: camera)
        } else {
            let editable = camera.state.connection.isControllable && !channels.isEmpty
            Tile(tint: camera.slot.tint, isEnabled: !channels.isEmpty) {
                let content = TileFrame(caption: "Audio") { oneLine, size in
                    let valueSize = Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s)
                    HStack(spacing: 4 * s) {
                        // Every channel's caption and gain where the tile is wide enough, then without "dB", then the
                        // gains alone.
                        Group {
                            if channels.isEmpty {
                                Text(verbatim: "—").font(Theme.value(valueSize)).foregroundStyle(Theme.text)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    ColumnsRow(spacing: 12 * s) {
                                        ForEach(channels) { gain($0, unit: true, size: valueSize) }
                                    }
                                    ColumnsRow(spacing: 10 * s) {
                                        ForEach(channels) { gain($0, unit: false, size: valueSize) }
                                    }
                                    Text(verbatim: channels.map { Self.gainText($0, unit: false) }.joined(separator: " · "))
                                        .font(Theme.value(valueSize))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                }
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if editable { SheetChevron() }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                if editable {
                    Button { presentTileSheet(.audio(camera.id)) } label: { content }.buttonStyle(.plain)
                } else {
                    content
                }
            }
        }
    }

    /// "CH1 +12 dB": grayed while nothing is plugged into the channel's input (the camera mutes it).
    private func gain(_ channel: AudioChannel, unit: Bool, size: CGFloat) -> some View {
        CaptionedValue(channel.name, Self.gainText(channel, unit: unit), size: size,
                       color: channel.isAvailable ? Theme.text : Theme.secondaryText)
    }

    /// The channel's gain ("+12 dB", "0 dB", "−6 dB"), else its input's name.
    static func gainText(_ channel: AudioChannel, unit: Bool) -> String {
        if let gain = channel.gain { return decibels(gain.shown, unit: unit) }
        return channel.input?.shown ?? "—"
    }

    /// A gain as a person reads one: whole decibels where it is whole, a sign before it, a true minus.
    static func decibels(_ value: Double, unit: Bool = true) -> String {
        let tenths = (value * 10).rounded() / 10
        let magnitude = abs(tenths)
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : String(format: "%.1f", magnitude)
        let sign = tenths > 0 ? "+" : tenths < 0 ? "\u{2212}" : ""
        return sign + number + (unit ? " dB" : "")
    }
}

/// A VENICE's audio meters (`Output.Audio.dBLevel`, four channels): a bar each, stacked as the camera's own viewfinder
/// stacks them, and side by side on one line. Read from `CameraController.audioMeters`, which changes several times a
/// second without touching the camera's state, so only this tile redraws with it. Grayed while the camera records no
/// sound (S&Q), as its own page grays them.
struct AudioMetersTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let count = camera.state.audioMeterCount
        let levels = camera.audioMeters
        let muted = camera.state.audioMetersMuted || levels == nil
        Tile(tint: camera.slot.tint, isEnabled: count > 0, isReadout: true) {
            TileFrame(caption: "Audio") { oneLine, size in
                AudioMeters(levels: (0..<count).map { levels?.indices.contains($0) == true ? levels![$0] : 0 },
                            muted: muted, oneLine: oneLine, size: size)
            }
        }
    }
}

/// The meters themselves: a channel's number and its bar, per channel. Stacked where they all fit, two by two where
/// they don't, else side by side on one line: never one cut off (a 66 pt iPad tile lost its fourth).
struct AudioMeters: View {
    var levels: [Double]
    var muted: Bool
    var oneLine: Bool
    var size: CGSize
    @Environment(\.tileScale) private var s

    var body: some View {
        if oneLine {
            line
        } else {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 3 * s) {
                    ForEach(levels.indices, id: \.self) { meter($0) }
                }
                Grid(horizontalSpacing: 12 * s, verticalSpacing: 3 * s) {
                    ForEach(Array(stride(from: 0, to: levels.count, by: 2)), id: \.self) { first in
                        GridRow {
                            meter(first)
                            if first + 1 < levels.count { meter(first + 1) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                line
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Side by side; too narrow for a number before each bar, the bars alone (in channel order).
    private var line: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8 * s) {
                ForEach(levels.indices, id: \.self) { meter($0, minBar: 18 * s) }
            }
            HStack(spacing: 4 * s) {
                ForEach(levels.indices, id: \.self) { bar($0).audited(.control) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func meter(_ index: Int, minBar: CGFloat = 0) -> some View {
        HStack(spacing: 5 * s) {
            Text(verbatim: "\(index + 1)")
                .font(Theme.caption(s))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            bar(index).frame(minWidth: minBar)
        }
        .audited(.control)
    }

    private func bar(_ index: Int) -> some View {
        MeterBar(level: muted ? 0 : levels[index], height: 6 * s)
            .opacity(muted ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Channel \(index + 1)")
            .accessibilityValue(muted ? "muted" : "\(Int((levels[index] * 100).rounded())) percent")
    }
}

/// One channel's level, 0…1 of the meter (Sony's 24 steps). Colored by where it reaches, as Sony's page colors its
/// segments (venice_outside_home_icon_14x4_audiolevel*.png): the quiet bottom 13 steps dim, then bright, the last red.
struct MeterBar: View {
    var level: Double
    var height: CGFloat

    /// Where the bright part and the red one start, as fractions of the meter.
    static let bright = 13.5 / 24
    static let over = 23.5 / 24

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control)
                HStack(spacing: 0) {
                    Theme.secondaryText.frame(width: width * Self.bright)
                    Theme.text.frame(width: width * (Self.over - Self.bright))
                    Theme.recording
                }
                .frame(width: width)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: width * min(max(level, 0), 1))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .animation(.linear(duration: 0.1), value: level)
    }
}
