import SwiftUI
import CameraCore

/// A tappable list row shared by the mesh-device list and the profile list: title, subtitle, and a trailing
/// "Added", checkmark, or optional status label. Disabled when already added.
struct SelectableRow: View {
    var title: String
    var subtitle: String
    var isAdded: Bool
    var isSelected: Bool
    var statusLabel: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isAdded ? Theme.sheet.secondaryText : Theme.sheet.text)
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.sheet.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if isAdded {
                    Text("Added").font(.caption).foregroundStyle(Theme.sheet.secondaryText)
                } else if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                } else if let statusLabel {
                    Text(statusLabel).font(.caption).foregroundStyle(Theme.sheet.secondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }
}

/// Add Camera: the devices on the HaLow mesh, from the nodes' DHCP leases and static leases. Tap one to use its
/// address (and, for a camera that says who made it, its type). Read when the form opens and on refresh, never polled.
struct MeshDevicesSection: View {
    let scan: () async -> MeshDeviceScan
    let existingHosts: Set<String>
    /// The address currently in the form, so the row it came from shows a checkmark.
    let selectedHost: String
    let onSelect: (MeshDevice) -> Void
    @State private var result: MeshDeviceScan?
    @State private var loading = false

    init(initial: MeshDeviceScan? = nil, scan: @escaping () async -> MeshDeviceScan, existingHosts: Set<String>,
         selectedHost: String, onSelect: @escaping (MeshDevice) -> Void) {
        self.scan = scan
        self.existingHosts = existingHosts
        self.selectedHost = selectedHost
        self.onSelect = onSelect
        _result = State(initialValue: initial)
    }

    var body: some View {
        Section {
            if let result {
                ForEach(result.devices) { device in row(device) }
                if result.devices.isEmpty && result.problems.isEmpty {
                    Text("Nothing on the mesh yet. A camera shows up here once it has joined a node, by Wi-Fi or cable.")
                        .font(.callout)
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                ForEach(result.problems.keys.sorted(), id: \.self) { node in
                    Label {
                        Text("\(node): \(result.problems[node] ?? "")")
                            .font(.callout)
                            .foregroundStyle(Theme.sheet.secondaryText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the nodes…").foregroundStyle(Theme.sheet.secondaryText)
                }
            }
        } header: {
            HStack {
                Text("On the HaLow Mesh")
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityLabel("Refresh")
            }
        } footer: {
            FooterText("From the nodes' DHCP leases and static leases; cameras that say who made them come first. Tap one to use its address.")
        }
        .task { if result == nil { await load() } }
    }

    private func row(_ device: MeshDevice) -> some View {
        let added = existingHosts.contains(device.ip)
        let selected = device.ip == selectedHost.trimmingCharacters(in: .whitespaces)
        return SelectableRow(
            title: device.name ?? device.ip,
            subtitle: subtitle(device),
            isAdded: added,
            isSelected: selected,
            statusLabel: device.isPresent ? nil : "Not on the mesh"
        ) { onSelect(device) }
    }

    private func subtitle(_ device: MeshDevice) -> String {
        var parts: [String] = []
        if device.name != nil { parts.append(device.ip) }
        if !device.mac.isEmpty { parts.append(device.mac) }
        if let node = device.node { parts.append(node) }
        if let maker = device.cameraMaker { parts.append(maker.label) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        result = await scan()
        loading = false
    }
}

#if os(macOS)
/// Add Camera on a Mac: Sony and Blackmagic cameras on this Mac's USB. Tap one to use it; a Sony camera in another USB
/// mode says how to switch. Read from the IORegistry (nothing is opened) when the form opens and every 2 s while it's
/// open, so a camera plugged in meanwhile appears. Each is saved as `usb:<serial>`, whichever port it's in.
struct USBCamerasSection: View {
    let existingHosts: Set<String>
    let selectedHost: String
    let onSelect: (_ host: String, _ type: CameraType) -> Void
    @State private var sony = USBCamera.connected()
    @State private var blackmagic = BlackmagicUSBCamera.connected()

    var body: some View {
        Section {
            ForEach(sony) { camera in
                SelectableRow(
                    title: camera.product,
                    subtitle: "USB · \(camera.serial)",
                    isAdded: existingHosts.contains(camera.host),
                    isSelected: camera.host == selectedHost,
                    statusLabel: camera.isRemoteShooting ? nil : "Not in Remote Shooting"
                ) { if camera.isRemoteShooting { onSelect(camera.host, .sony) } }
            }
            ForEach(blackmagic) { camera in
                SelectableRow(
                    title: camera.product,
                    subtitle: "USB · \(USBCameraAddress.label(serial: camera.serial))",
                    isAdded: existingHosts.contains(camera.host),
                    isSelected: camera.host == selectedHost
                ) { onSelect(camera.host, .blackmagic) }
            }
            if sony.isEmpty && blackmagic.isEmpty {
                Text("None. Connect a Sony or Blackmagic camera with a USB-C cable.")
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.secondaryText)
            }
        } header: {
            Text("On USB")
        } footer: {
            FooterText("Sony: on the camera, MENU → Setup → USB → USB Connection Mode → Remote Shooting. Blackmagic: Remote Control or Network Access on, as on a network.")
        }
        .task {
            while !Task.isCancelled {
                sony = USBCamera.connected()
                blackmagic = BlackmagicUSBCamera.connected()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
#endif

#if os(iOS) && canImport(ImageCaptureCore)
import ImageCaptureCore

/// Add Camera on iPhone and iPad: a camera on the USB-C port. A Blackmagic camera is listed as soon as its Bonjour
/// advert comes over the cable, or over an iPhone's Personal Hotspot (the camera on its USB-C joins it), and saved as `usb:<serial>` (its unique id, the serial a Mac sees), the list looked at
/// every second while the form is open. A Sony camera is found through ImageCaptureCore: looking asks for permission to
/// control cameras the first time, so it waits for a tap, and it's saved as `usb:<name>`, as ImageCaptureCore gives
/// apps its name, not its serial number.
struct USBCamerasSection: View {
    let existingHosts: Set<String>
    let selectedHost: String
    let onSelect: (_ host: String, _ type: CameraType) -> Void
    @State private var finder = USBCameraFinder()
    @State private var blackmagic = BlackmagicAdverts.shared.onCables()

    var body: some View {
        Section {
            ForEach(blackmagic, id: \.serial) { camera in
                SelectableRow(
                    title: camera.product,
                    subtitle: "USB · \(USBCameraAddress.label(serial: camera.serial))",
                    isAdded: existingHosts.contains(camera.host),
                    isSelected: camera.host == selectedHost
                ) { onSelect(camera.host, .blackmagic) }
            }
            ForEach(finder.names, id: \.self) { name in
                let host = USBCameraAddress.host(serial: name)
                SelectableRow(title: name, subtitle: "USB", isAdded: existingHosts.contains(host),
                              isSelected: host == selectedHost) { onSelect(host, .sony) }
            }
            switch finder.status {
            case .idle:
                Button {
                    finder.start()
                } label: {
                    Label("Find a Camera on USB", systemImage: "cable.connector")
                }
            case .looking where finder.names.isEmpty:
                Text("Looking… Connect the camera with a USB-C cable.")
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.secondaryText)
            case .looking:
                EmptyView()
            case .notAllowed:
                Text("Tiles isn't allowed to control cameras. Allow it in Settings → Tiles.")
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.secondaryText)
            }
        } header: {
            Text("On USB")
        } footer: {
            FooterText("Sony: on the camera, MENU → Setup → USB → USB Connection Mode → Remote Shooting. Blackmagic: Remote Control or Network Access on, as on a network, and on an iPhone, Personal Hotspot on (Allow Others to Join).")
        }
        .task {
            BlackmagicAdverts.shared.start()
            let opened = ContinuousClock.now
            var said = ""
            while !Task.isCancelled {
                blackmagic = BlackmagicAdverts.shared.onCables()
                // None after a while: what the browse sees, once for each picture, for the Activity Log (a camera's link
                // takes a few seconds to come up after the cable goes in).
                if blackmagic.isEmpty, ContinuousClock.now - opened > .seconds(8) {
                    let seen = BlackmagicAdverts.shared.describe()
                    if seen != said {
                        said = seen
                        ActivityLog.shared.note("On USB", "no Blackmagic camera on a cable: \(seen)")
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { finder.stop() }
    }
}

@MainActor @Observable
final class USBCameraFinder: NSObject, ICDeviceBrowserDelegate {
    enum Status { case idle, looking, notAllowed }
    private(set) var status: Status = .idle
    private(set) var names: [String] = []
    @ObservationIgnored private var browser: ICDeviceBrowser?

    func start() {
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        self.browser = browser
        browser.requestControlAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.status = .notAllowed; return }
                self.status = .looking
                self.browser?.start()
            }
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let name = device.name, device is ICCameraDevice else { return }
        Task { @MainActor in if !self.names.contains(name) { self.names.append(name) } }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let name = device.name else { return }
        Task { @MainActor in self.names.removeAll { $0 == name } }
    }
}
#endif
