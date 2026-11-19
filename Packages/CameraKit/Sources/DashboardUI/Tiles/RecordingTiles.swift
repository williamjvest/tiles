import SwiftUI
import CameraCore

// MARK: - Recording

/// REC. Never optimistic: dims while the camera hasn't confirmed, and stays disabled until we know whether the
/// camera is already recording. Standby is an unlit REC button; recording lights it red as STOP.
struct RecordTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let rec = camera.state.recording
        let isRecording = rec.state == .recording
        let canPress = camera.state.connection.isControllable && rec.state != .unknown && rec.request == nil
        Tile(
            tint: isRecording ? Theme.recording : camera.slot.tint,
            badge: rec.failure != nil ? "REC FAILED" : nil,
            badgeColor: .orange,
            isEnabled: camera.state.connection.isControllable,
            // Rolling, STOP is the tally: it stays bright while the controls are locked.
            isReadout: isRecording
        ) {
            Button {
                camera.send(.record(!isRecording))
            } label: {
                GeometryReader { geo in
                    let size = min(geo.size.width, geo.size.height) * 0.62
                    Group {
                        // A circle in every size: unlit REC, red STOP when rolling.
                        if isRecording {
                            Circle()
                                .fill(Theme.recording)
                                .frame(width: size, height: size)
                                .overlay(
                                    Text("STOP")
                                        .font(Theme.hero(size * 0.24))
                                        .foregroundStyle(.white)
                                )
                        } else {
                            // Standby: the same button, unlit. Red ring and "REC", dark fill.
                            Circle()
                                .fill(Theme.style.recFill)
                                .overlay(Circle().strokeBorder(Theme.recording.opacity(0.9), lineWidth: max(2, size * 0.06)))
                                .frame(width: size, height: size)
                                .overlay(
                                    Text("REC")
                                        .font(Theme.hero(size * 0.24))
                                        .foregroundStyle(Theme.recording)
                                )
                        }
                    }
                    .opacity(rec.request != nil ? 0.4 : 1)
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Why, under the button, where there's room for it whole: the badge said REC FAILED and nothing
                    // more, and each camera's reason was only in the Activity Log (the 11/16 UI audit).
                    .overlay(alignment: .bottom) {
                        if let failure = rec.failure, (geo.size.height - size) / 2 >= 22 * s {
                            ViewThatFits(in: .horizontal) {
                                Text(failure).fixedSize()
                                Color.clear.frame(width: 0, height: 0)
                            }
                            .font(Theme.readout(s))
                            .foregroundStyle(Theme.legible(.orange))
                            .padding(.horizontal, Theme.inset * s)
                            .padding(.bottom, Theme.insetV * s)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPress)
            .accessibilityValue(rec.failure.map { "REC failed: \($0)" }
                                ?? (rec.request != nil ? "Waiting for the camera" : isRecording ? "Recording" : ""))
        }
    }
}

/// Tappable picker for resolution (from camera-offered options). A choice that restarts the camera (a VENICE's
/// imager mode) is confirmed first.
struct ResolutionTile: View {
    let camera: CameraController
    @State private var pending: String?
    @Environment(\.tileScale) private var s

    var body: some View {
        let res = camera.state.resolution
        let live = camera.state.connection.isControllable && res?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: res != nil) {
            TileFrame(caption: "Res", valueWins: true) { oneLine, size in
                PickerValue(text: res?.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: res?.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine) { picked in
                    if res?.restartRequired.contains(picked) == true { pending = picked } else { camera.send(.setResolution(picked)) }
                }
            }
        }
        .restartConfirmation($pending) { camera.send(.setResolution($0)) }
    }
}

/// Codec (Sony's file format). Bitrate has its own tile. A format that restarts the camera (X-OCN ↔ ProRes on a
/// VENICE) is confirmed first.
struct CodecTile: View {
    let camera: CameraController
    @State private var pending: String?
    @Environment(\.tileScale) private var s

    var body: some View {
        let fmt = camera.state.fileFormat
        let live = camera.state.connection.isControllable && fmt?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: fmt != nil) {
            TileFrame(caption: "Codec", valueWins: true) { oneLine, size in
                PickerValue(text: fmt?.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: fmt?.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine) { picked in
                    if fmt?.restartRequired.contains(picked) == true { pending = picked } else { camera.send(.setFileFormat(picked)) }
                }
            }
        }
        .restartConfirmation($pending) { camera.send(.setFileFormat($0)) }
    }
}

extension View {
    /// "Switch to X? (restarts camera)": the same confirmation the frame rate tile asks.
    func restartConfirmation(_ pending: Binding<String?>, perform: @escaping (String) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue.map { "Switch to \($0)?" } ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            if let value = pending.wrappedValue {
                Button("Switch to \(value) (restarts camera)") {
                    perform(value)
                    pending.wrappedValue = nil
                }
                Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
            }
        }
    }
}

/// The gamma the camera records and shows: Blackmagic's dynamic range ("Film", "Extended Video", "Video").
struct DynamicRangeTile: View {
    let camera: CameraController

    var body: some View {
        ChoiceTile(camera: camera, caption: "Dynamic Range", choice: camera.state.dynamicRange) { .setDynamicRange($0) }
    }
}

/// One setting the camera names and lists, picked from its list: a caption over the value, ⌄ to choose. Dynamic Range,
/// and the BURANO's ND mode, tally and color gamut.
struct ChoiceTile: View {
    let camera: CameraController
    let caption: String
    let choice: Choice<String>?
    let command: (String) -> CameraCommand
    @Environment(\.tileScale) private var s

    var body: some View {
        let live = camera.state.connection.isControllable && choice?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: choice != nil) {
            TileFrame(caption: caption, valueWins: true) { oneLine, size in
                PickerValue(text: choice?.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: choice?.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine) { camera.send(command($0)) }
            }
        }
    }
}

/// Bitrate and sampling (Sony's Recording Setting), e.g. "600M 4:2:2 10bit". Its own tile, apart from codec.
struct BitrateTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let rec = camera.state.recordingSetting
        let live = camera.state.connection.isControllable && rec?.isWritable == true
        // "240M 4:2:2 10bit": the rate is the headline, the sampling rides after it smaller.
        let parts = (rec?.shown ?? "—").split(separator: " ", maxSplits: 1).map(String.init)
        Tile(tint: camera.slot.tint, isEnabled: rec != nil) {
            TileFrame(caption: "Bitrate", valueWins: true) { oneLine, size in
                PickerValue(text: parts.first ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: rec?.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine, detail: parts.count > 1 ? parts[1] : nil) { camera.send(.setRecordingSetting($0)) }
            }
        }
    }
}

/// Picker for anamorphic de-squeeze setting.
struct DesqueezeTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let dsq = camera.state.desqueeze
        let live = camera.state.connection.isControllable && dsq?.isWritable == true
        Tile(tint: camera.slot.tint, isEnabled: dsq != nil) {
            TileFrame(caption: "De-squeeze", valueWins: true) { oneLine, size in
                PickerValue(text: dsq?.shown ?? "—", size: Theme.valueSize(oneLine: oneLine, height: size.height, max: Theme.textValueMax, scale: s),
                            options: dsq?.options ?? [], title: { $0 }, isLive: live,
                            multiline: !oneLine) { camera.send(.setDesqueeze($0)) }
            }
        }
    }
}

/// Recording format, e.g. "3840x2160" over "UHD · XAVC S-I".
struct FormatTile: View {
    let camera: CameraController
    @Environment(\.tileScale) private var s

    var body: some View {
        let parts = (camera.state.recordingFormat ?? "—").components(separatedBy: " · ")
        Tile(tint: camera.slot.tint, isEnabled: camera.state.recordingFormat != nil, isReadout: true) {
            TileFrame(caption: "Format") { oneLine, size in
                HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                    Text(verbatim: parts.first ?? "—")
                        .font(Theme.value(oneLine ? Theme.oneLineValue * s
                                          : Theme.valueSize(size.height - 14 * s, max: Theme.textValueMax, scale: s)))
                        // With the link down it's what the camera last said: grayed, as a stale value is.
                        .foregroundStyle(camera.state.connection == .connected ? Theme.text : Theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .layoutPriority(1)
                    if parts.count > 1 {
                        Caption(parts.dropFirst().joined(separator: " · "))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
