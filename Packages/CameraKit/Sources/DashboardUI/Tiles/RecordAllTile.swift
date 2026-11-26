import SwiftUI
import CameraCore

/// One REC button for every camera on the page. With any camera rolling a tap stops every rolling one; otherwise it
/// starts every idle one. Each camera follows its own REC path (and its own confirmation), and the tile shows each
/// camera's state inside it as a letter in a ring, so it never says rolling for a camera that hasn't confirmed. A
/// camera that's offline or still connecting is left out rather than holding up the others.
///
/// The tile belongs to one camera (PageWidget.cameraID) but reads the full camera list from the store,
/// the same way the frame-rate tile reads its linked peers.
struct RecordAllTile: View {
    let camera: CameraController
    let store: DashboardStore?
    @Environment(\.tileScale) private var s
    @Environment(\.controlsLocked) private var locked

    var body: some View {
        // All cameras on the current page, falling back to just this tile's camera when the store is absent
        // (gallery, previews).
        let all = store?.visibleCameras ?? [camera]
        let anyRolling = all.contains { $0.state.recording.state == .recording }
        // The cameras a tap reaches: connected and reported. One that's down mustn't stop the rest rolling.
        let reachable = all.filter { $0.state.connection.isControllable && $0.state.hasReported }
        // A start still being confirmed holds a second start, never a stop.
        let anyPending = all.contains { $0.state.recording.request != nil }
        let canPress = !reachable.isEmpty && (anyRolling || !anyPending) && !locked

        // Fill red when any camera is rolling so STOP reads immediately.
        Tile(
            tint: anyRolling ? Theme.recording : camera.slot.tint,
            isEnabled: !reachable.isEmpty,
            isReadout: anyRolling
        ) {
            Button {
                // If any camera is rolling, stop all rolling ones; otherwise start all idle ones.
                for cam in reachable {
                    let state = cam.state.recording.state
                    if anyRolling {
                        if state == .recording { cam.send(.record(false)) }
                    } else {
                        if state == .idle { cam.send(.record(true)) }
                    }
                }
            } label: {
                GeometryReader { geo in
                    // A row of camera markers under the circle, the circle as big as the rest allows.
                    let markers = 22 * s
                    let showMarkers = geo.size.height >= 70 * s
                    let size = min(geo.size.width, geo.size.height - (showMarkers ? markers + 8 * s : 0)) * 0.7
                    VStack(spacing: 6 * s) {
                        Group {
                            if anyRolling {
                                Circle()
                                    .fill(Theme.recording)
                                    .frame(width: size, height: size)
                                    .overlay(Text("STOP").font(Theme.hero(size * 0.24)).foregroundStyle(.white))
                            } else {
                                Circle()
                                    .fill(Theme.style.recFill)
                                    .overlay(Circle().strokeBorder(Theme.recording.opacity(0.9), lineWidth: max(2, size * 0.06)))
                                    .frame(width: size, height: size)
                                    .overlay(Text("REC").font(Theme.hero(size * 0.24)).foregroundStyle(Theme.recording))
                            }
                        }
                        .opacity(anyPending ? 0.4 : 1)
                        if showMarkers {
                            HStack(spacing: 6 * s) {
                                ForEach(all) { cam in CameraStateDot(camera: cam, scale: s, diameter: markers) }
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPress)
            .accessibilityLabel("Record all")
            .accessibilityValue(accessibilityValue(for: all))
        }
    }

    private func accessibilityValue(for cameras: [CameraController]) -> String {
        cameras.map { cam in
            let state: String
            switch cam.state.recording.state {
            case .recording: state = "rolling"
            case .idle: state = "idle"
            case .unknown: state = "unknown"
            }
            return "\(cam.slot.label) \(state)"
        }.joined(separator: ", ")
    }
}

/// A small letter badge that shows one camera's recording state: letter in its slot color, ring color by state.
private struct CameraStateDot: View {
    let camera: CameraController
    let scale: CGFloat
    let diameter: CGFloat

    var body: some View {
        let rec = camera.state.recording
        let ringColor: Color = switch rec.state {
        case .recording: Theme.recording
        case .idle:      Theme.timecode
        case .unknown:   Theme.secondaryText
        }
        ZStack {
            Circle()
                .fill(rec.state == .recording ? Theme.recording.opacity(0.25) : .clear)
                .frame(width: diameter, height: diameter)
            Circle()
                .strokeBorder(ringColor, lineWidth: max(1.5, diameter * 0.1))
                .frame(width: diameter, height: diameter)
            Text(camera.slot.label)
                .font(.system(size: diameter * 0.5, weight: .bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(Theme.legible(camera.slot.tint))
                .frame(width: diameter * 0.7)
        }
        .opacity(rec.request != nil ? 0.5 : 1)
    }
}
