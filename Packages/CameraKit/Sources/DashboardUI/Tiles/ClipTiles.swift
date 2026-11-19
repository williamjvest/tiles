import SwiftUI
import CameraCore

// MARK: - Clips

/// Opens the camera's clips (`ClipListView`). Offered where the camera plays a clip picked by its place
/// (`PlaybackCapabilities.goToClip`).
struct ClipsTile: View {
    let camera: CameraController
    @Environment(\.presentTileSheet) private var presentTileSheet

    var body: some View {
        let has = camera.state.playback?.capabilities.goToClip == true
        Tile(tint: camera.slot.tint, isEnabled: has) {
            Button { presentTileSheet(.clips(camera.id)) } label: {
                WindowButtonLabel(title: "Clips")
            }
            .buttonStyle(.plain)
            .disabled(!camera.state.connection.isControllable || !has)
        }
    }
}

/// The camera's clips in its order, the newest last, as its own clip list has them: each one's number, name and length
/// where the camera says (a Blackmagic camera names every one; an FX5, a VENICE or an ALEXA only the open one). A tap
/// plays that clip (`PlaybackCommand.goToClip`): a Blackmagic camera seeks to its start, the others step there a clip
/// at a time. Latest Take is the Playback tile's Review, or the last clip once in review. Not while recording.
struct ClipListView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = camera.state
        let pb = state.playback
        let canPick = state.connection.isControllable && state.recording.state == .idle && state.recording.request == nil
        let clips = pb?.clipListing
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        // Review from the live picture; in review, the last clip on the list.
                        let reviewing = pb?.inReview == true
                        Button {
                            if reviewing, let last = clips?.last {
                                camera.send(.playback(.goToClip(last.id)))
                            } else {
                                camera.send(.playback(.review))
                            }
                        } label: {
                            Label("Latest Take", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(!canPick || (reviewing ? clips?.isEmpty != false : pb?.capabilities.review != true))
                    } footer: {
                        if state.recording.state != .idle {
                            FooterText("Not while recording.")
                        } else if clips == nil {
                            FooterText("This camera numbers its clips only while it's playing one back: Latest Take "
                                       + "opens the newest, and they're listed here.")
                        }
                    }
                    if let clips {
                        Section {
                            if clips.isEmpty {
                                Text("No clips")
                                    .foregroundStyle(Theme.sheet.secondaryText)
                            }
                            ForEach(clips) { clip in
                                row(clip, open: pb?.inReview != false && pb?.clipNumber == clip.id + 1,
                                    playing: pb?.isPlaying == true, enabled: canPick)
                                    .id(clip.id)
                            }
                        } header: {
                            Text(clips.count == 1 ? "1 clip" : "\(clips.count) clips")
                        } footer: {
                            if pb?.latestTakeMissing == true {
                                FooterText("The camera's playback list doesn't have the latest take on its card: Play "
                                           + "on the camera itself shows it.")
                            } else if pb?.clips == nil, !clips.isEmpty {
                                FooterText("The camera goes to a clip one at a time from the one it has open, so a "
                                           + "clip far away takes a few seconds.")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    // The open clip, else the newest: where an operator looks first.
                    if let id = (pb?.clipNumber).map({ $0 - 1 }) ?? clips?.last?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .navigationTitle("Clips")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ clip: PlaybackClip, open: Bool, playing: Bool, enabled: Bool) -> some View {
        Button {
            camera.send(.playback(.goToClip(clip.id)))
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: "\(clip.id + 1)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.sheet.secondaryText)
                    .frame(minWidth: 32, alignment: .trailing)
                Text(verbatim: clip.name ?? "Clip \(clip.id + 1)")
                    .fontWeight(open ? .semibold : nil)
                    .foregroundStyle(open ? Color.accentColor : clip.name == nil ? Theme.sheet.secondaryText : Theme.sheet.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let seconds = clip.seconds {
                    Text(verbatim: PlaybackTile.clock(seconds))
                        .monospacedDigit()
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                Image(systemName: playing ? "play.fill" : "pause.fill")
                    .foregroundStyle(Color.accentColor)
                    .opacity(open ? 1 : 0)
                    .accessibilityHidden(!open)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(clip.name ?? "Clip \(clip.id + 1)")
        .accessibilityValue(open ? (playing ? "playing" : "open") : "")
    }
}
