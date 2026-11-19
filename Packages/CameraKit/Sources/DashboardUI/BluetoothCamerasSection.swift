#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import CameraCore
import SwiftUI

/// Add Camera: Blackmagic cameras within Bluetooth range, by the camera control service they advertise. Looking asks
/// for Bluetooth permission the first time, so it waits for a tap rather than asking whenever Add Camera opens.
struct BluetoothCamerasSection: View {
    let existingHosts: Set<String>
    let selectedHost: String
    let onSelect: (_ id: UUID, _ name: String) -> Void
    @State private var finder = BluetoothCameraFinder()

    var body: some View {
        Section {
            ForEach(finder.cameras) { camera in
                let host = BluetoothCameraAddress.host(id: camera.id)
                SelectableRow(title: camera.name, subtitle: "Bluetooth", isAdded: existingHosts.contains(host),
                              isSelected: host == selectedHost) { onSelect(camera.id, camera.name) }
            }
            if !finder.isLooking {
                Button("Look for Blackmagic Cameras") { finder.start() }
            } else if let problem = finder.problem {
                Text(problem).font(.callout).foregroundStyle(Theme.sheet.secondaryText)
            } else if finder.cameras.isEmpty {
                Text("Looking…").font(.callout).foregroundStyle(Theme.sheet.secondaryText)
            }
        } header: {
            Text("Over Bluetooth")
        } footer: {
            FooterText("Blackmagic cameras with Bluetooth on (their Setup menu), in the same room: URSA Mini Pro, Pocket cameras, PYXIS, URSA Cine. The first connection shows a 6-digit code on the camera to type into the pairing prompt that comes up.")
        }
        .onDisappear { finder.stop() }
    }
}

/// A Blackmagic camera a scan found.
struct NearbyBluetoothCamera: Identifiable, Hashable {
    /// This device's identifier for it.
    let id: UUID
    let name: String
}

/// Scans for Blackmagic's camera service on the main queue.
@MainActor @Observable
final class BluetoothCameraFinder: NSObject, CBCentralManagerDelegate {
    private(set) var cameras: [NearbyBluetoothCamera] = []
    private(set) var isLooking = false
    private(set) var problem: String?
    @ObservationIgnored private var central: CBCentralManager?
    private static let service = CBUUID(string: "291D567A-6D75-11E6-8B77-86F30CA893D3")  // BlackmagicBluetooth.cameraService

    func start() {
        isLooking = true
        if let central { scan(central) } else { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func stop() {
        central?.stopScan()
    }

    private func scan(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        problem = nil
        central.scanForPeripherals(withServices: [Self.service])
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: scan(central)
            case .unauthorized: problem = "Tiles isn't allowed to use Bluetooth: turn it on in Settings, Privacy, Bluetooth."
            case .poweredOff: problem = "Bluetooth is off on this device."
            case .unsupported: problem = "This device has no Bluetooth LE."
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Blackmagic camera"
        MainActor.assumeIsolated {
            if let i = cameras.firstIndex(where: { $0.id == id }) {
                if cameras[i].name != name { cameras[i] = NearbyBluetoothCamera(id: id, name: name) }
            } else {
                cameras.append(NearbyBluetoothCamera(id: id, name: name))
            }
        }
    }
}
#endif
