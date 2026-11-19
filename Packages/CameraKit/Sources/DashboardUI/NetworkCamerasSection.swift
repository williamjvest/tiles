import CameraCore
import SwiftUI

/// Add Camera: the cameras on this device's networks, every maker in one list (`NetworkCameras`), each as it's found.
/// Tap one to use its address and type; a Sony with Access Authentication on turns it on here too, for its login.
struct NetworkCamerasSection: View {
    let existingHosts: Set<String>
    /// The address currently in the form, so the row it came from shows a checkmark.
    let selectedHost: String
    /// On a HaLow mesh: its devices' addresses, asked instead of every address of the network (`NetworkCameras`).
    var meshHosts: (() async -> [String])? = nil
    let onSelect: (NetworkCamera) -> Void
    @State private var cameras: [NetworkCamera] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        Section {
            ForEach(cameras) { camera in row(camera) }
            if searching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking for cameras…").foregroundStyle(Theme.sheet.secondaryText)
                }
            } else if cameras.isEmpty && searched {
                Text("None found. A Sony camera shows up here once it's on this network with Camera Remote Control on, a "
                     + "Blackmagic camera once it's on the network at all.")
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.secondaryText)
            }
        } header: {
            HStack {
                Text("On This Network")
                Spacer()
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(searching)
                .accessibilityLabel("Search again")
            }
        } footer: {
            FooterText("Sony and Blackmagic cameras. ARRI cameras and Sony's VENICE don't announce themselves on the "
                       + "network, so type their address. Tap one to use it.")
        }
        .task { if !searched { await search() } }
    }

    private func row(_ camera: NetworkCamera) -> some View {
        SelectableRow(
            title: camera.name,
            subtitle: [camera.maker.label, camera.host, camera.model, camera.needsLogin ? "Access Authentication" : nil]
                .compactMap { $0 }.joined(separator: " · "),
            isAdded: existingHosts.contains(camera.host),
            isSelected: camera.host == selectedHost.trimmingCharacters(in: .whitespaces)
        ) { onSelect(camera) }
    }

    private func search() async {
        searching = true
        cameras = []
        let hosts = await meshHosts?()
        for await camera in NetworkCameras.search(hosts: hosts) {
            cameras.append(camera)
            cameras.sort { (LocalIPv4.value($0.host) ?? 0) < (LocalIPv4.value($1.host) ?? 0) }
        }
        searching = false
        // Cut short (the form scrolled the list away, or closed): searched afresh when it's back, not left at a
        // partial list, or "None found".
        if !Task.isCancelled { searched = true }
    }
}
