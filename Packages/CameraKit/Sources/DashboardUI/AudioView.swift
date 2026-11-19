import SwiftUI
import CameraCore

/// A Blackmagic camera's audio channels (`CameraState.audioChannels`): each one's input, its gain, and
/// phantom power, the low-cut filter and the pad where its input has them. Each change is the camera's to confirm. A
/// sheet, so it keeps the standard look (`Theme.sheet`; SheetColourTests checks this file).
struct AudioView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let live = camera.state.connection.isControllable
        NavigationStack {
            Form {
                ForEach(camera.state.audioChannels) { channel in
                    Section {
                        if let input = channel.input {
                            Picker("Input", selection: Binding(get: { input.shown },
                                                               set: { send(channel, .input($0)) })) {
                                ForEach(input.options, id: \.self) { Text(verbatim: $0).tag($0) }
                            }
                            .disabled(!live || !input.isWritable)
                        }
                        if let gain = channel.gain {
                            GainRow(gain: gain, isEnabled: live && gain.isWritable) { send(channel, .gain($0)) }
                        }
                        if let phantom = channel.phantomPower {
                            Toggle("Phantom Power (48 V)", isOn: Binding(get: { phantom.shown },
                                                                         set: { send(channel, .phantomPower($0)) }))
                                .disabled(!live || !phantom.isWritable)
                        }
                        if let lowCut = channel.lowCut {
                            Toggle("Low Cut", isOn: Binding(get: { lowCut.shown }, set: { send(channel, .lowCut($0)) }))
                                .disabled(!live || !lowCut.isWritable)
                        }
                        if let pad = channel.pad {
                            Toggle("Pad", isOn: Binding(get: { pad.shown }, set: { send(channel, .pad($0)) }))
                                .disabled(!live || !pad.isWritable)
                        }
                    } header: {
                        Text(verbatim: "Channel \(channel.id + 1)")
                    } footer: {
                        if !channel.isAvailable {
                            FooterText("Nothing is plugged into this input, so the camera mutes the channel.")
                        } else if channel.pad?.isWritable == false {
                            FooterText("This input always has its pad on.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Audio")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func send(_ channel: AudioChannel, _ setting: AudioSetting) {
        camera.send(.setAudio(channel: channel.id, setting))
    }
}

/// A channel's gain: a slider across its input's range that sends on release (a drag doesn't flood the link), with the
/// value in dB. What was sent shows until the camera answers, or for 3 s if it never does, so the knob doesn't jump back.
private struct GainRow: View {
    let gain: Level
    let isEnabled: Bool
    let onCommit: (Double) -> Void
    @State private var dragged: Double?
    @State private var sent: Double?

    var body: some View {
        let shown = dragged ?? sent ?? gain.shown
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gain")
                Spacer()
                Text(verbatim: AudioTile.decibels(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { shown }, set: { dragged = $0 }), in: gain.range, step: gain.step) { editing in
                guard !editing, let value = dragged else { return }
                sent = value
                dragged = nil
                onCommit(value)
            }
            .disabled(!isEnabled)
            .accessibilityValue(AudioTile.decibels(shown))
        }
        .onChange(of: gain.value) { sent = nil }
        .task(id: sent) {
            guard sent != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { sent = nil }
        }
    }
}
