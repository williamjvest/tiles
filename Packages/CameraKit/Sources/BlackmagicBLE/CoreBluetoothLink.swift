#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

/// The Bluetooth link to one Blackmagic camera, by the identifier this device knows it by (from
/// `BlackmagicBluetoothScanner`). Found by identifier, or by scanning for Blackmagic's camera service when the system
/// has forgotten it; connected with no timeout, so a camera out of range is joined when it comes back.
///
/// Bonding is the system's: the first subscription to an encrypted characteristic makes the camera show a 6-digit
/// code and this device ask for it. Until that's done the subscription fails with an
/// authentication error; the link reports `.pairing` and tries again every few seconds.
///
/// Everything here runs on one serial queue, CoreBluetooth's delegate queue.
public final class CoreBluetoothLink: NSObject, BluetoothLink, @unchecked Sendable {
    public let events: AsyncStream<BluetoothLinkEvent>
    private let continuation: AsyncStream<BluetoothLinkEvent>.Continuation
    private let peripheralID: UUID
    /// Shown in the camera's Bluetooth menu.
    private let deviceName: String
    private let queue = DispatchQueue(label: "tiles.blackmagic-bluetooth")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var model: String?
    private var wantsOpen = false
    private var ready = false
    private var subscribed: Set<CBUUID> = []
    /// Writes waiting for the camera's acknowledgement, oldest first, each with a number for its timeout.
    private var writes: [(id: Int, done: CheckedContinuation<Void, Error>)] = []
    private var nextWrite = 0
    private var scanTimeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?

    private static let cameraService = CBUUID(string: BlackmagicBluetooth.cameraService)
    private static let deviceInformation = CBUUID(string: BlackmagicBluetooth.deviceInformationService)
    private static let outgoing = CBUUID(string: BlackmagicBluetooth.outgoingCameraControl)
    private static let incoming = CBUUID(string: BlackmagicBluetooth.incomingCameraControl)
    private static let timecode = CBUUID(string: BlackmagicBluetooth.timecode)
    private static let status = CBUUID(string: BlackmagicBluetooth.cameraStatus)
    private static let name = CBUUID(string: BlackmagicBluetooth.deviceName)
    private static let modelNumber = CBUUID(string: BlackmagicBluetooth.model)
    private static let protocolVersion = CBUUID(string: BlackmagicBluetooth.protocolVersion)
    /// Subscribed in this order; incoming and status make the link ready.
    private static let notifying = [status, incoming, timecode]

    public init(peripheralID: UUID, deviceName: String = "Tiles") {
        self.peripheralID = peripheralID
        self.deviceName = String(deviceName.prefix(32))
        let stream = AsyncStream.makeStream(of: BluetoothLinkEvent.self, bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        super.init()
    }

    public func open() async {
        queue.async { [self] in
            wantsOpen = true
            if let central { start(central) } else {
                central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
            }
        }
    }

    public func close() async {
        queue.async { [self] in
            wantsOpen = false
            central?.stopScan()
            let p = peripheral
            reset()
            if let p { central?.cancelPeripheralConnection(p) }
        }
    }

    public func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard ready, let peripheral, let out = characteristics[Self.outgoing] else {
                    done.resume(throwing: BluetoothLinkError.notReady)
                    return
                }
                if out.properties.contains(.write) {
                    // Answered in order by didWriteValueFor; one that never is fails after 3 s rather than hanging REC.
                    nextWrite += 1
                    let id = nextWrite
                    writes.append((id, done))
                    peripheral.writeValue(bytes, for: out, type: .withResponse)
                    queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, let i = self.writes.firstIndex(where: { $0.id == id }) else { return }
                        self.writes.remove(at: i).done.resume(throwing: BluetoothLinkError.writeFailed("no answer from the camera"))
                    }
                } else {
                    peripheral.writeValue(bytes, for: out, type: .withoutResponse)
                    done.resume()
                }
            }
        }
    }

    // MARK: - On the queue

    private func emit(_ event: BluetoothLinkEvent) { continuation.yield(event) }

    private func start(_ central: CBCentralManager) {
        guard wantsOpen, central.state == .poweredOn, peripheral == nil else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            connect(known)
            return
        }
        central.scanForPeripherals(withServices: [Self.cameraService])
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil, self.wantsOpen else { return }
            central.stopScan()
            self.emit(.closed("Camera not found over Bluetooth. Is it on and nearby, with Bluetooth on in its setup menu?"))
        }
        scanTimeout = timeout
        queue.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func connect(_ found: CBPeripheral) {
        scanTimeout?.cancel()
        central?.stopScan()
        peripheral = found
        found.delegate = self
        central?.connect(found)
    }

    /// Forget this connection's characteristics and answer any write still waiting.
    private func reset() {
        ready = false
        subscribed = []
        characteristics = [:]
        peripheral = nil
        scanTimeout?.cancel()
        retry?.cancel()
        let waiting = writes
        writes = []
        for write in waiting { write.done.resume(throwing: BluetoothLinkError.notReady) }
    }

    private func subscribe(_ uuid: CBUUID) {
        guard let peripheral, let characteristic = characteristics[uuid] else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// The camera's characteristics are known: read what needs no bonding, then subscribe, which bonds.
    private func characteristicsFound() {
        guard characteristics[Self.incoming] != nil else {
            emit(.closed("The camera has no camera control characteristic."))
            return
        }
        // Not encrypted. Read as Blackmagic's own app would, in case the camera waits for it ("versions verified").
        if let version = characteristics[Self.protocolVersion] { peripheral?.readValue(for: version) }
        for uuid in Self.notifying { subscribe(uuid) }
    }

    private func isAuthenticationError(_ error: Error) -> Bool {
        if let cb = error as? CBError, cb.code == .encryptionTimedOut { return true }  // the code wasn't typed in time
        guard let att = error as? CBATTError else { return false }
        return att.code == .insufficientAuthentication || att.code == .insufficientEncryption
    }

    /// An error as the camera tile says it; the one a person can fix gets the fix.
    private func describe(_ error: Error) -> String {
        if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
            return "The camera has forgotten this device. Remove it in Settings, Bluetooth, then connect again."
        }
        return error.localizedDescription
    }

    private func becameReady() {
        guard !ready, subscribed.contains(Self.incoming) else { return }
        ready = true
        retry?.cancel()
        emit(.ready(model: model))
        if let status = characteristics[Self.status] { peripheral?.readValue(for: status) }
        if let name = characteristics[Self.name] {
            peripheral?.writeValue(Data(deviceName.utf8), for: name, type: name.properties.contains(.write) ? .withResponse : .withoutResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            start(central)
        case .unauthorized:
            emit(.closed("Tiles isn't allowed to use Bluetooth: turn it on in Settings, Privacy, Bluetooth."))
        case .poweredOff:
            reset()
            emit(.closed("Bluetooth is off on this device."))
        case .unsupported:
            emit(.closed("This device has no Bluetooth LE."))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard found.identifier == peripheralID, peripheral == nil else { return }
        connect(found)
    }

    public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        connected.discoverServices([Self.deviceInformation, Self.cameraService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        reset()
        emit(.closed(error.map(describe) ?? "Couldn't connect to the camera over Bluetooth."))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral, error: Error?) {
        let wasReady = ready
        reset()
        guard wantsOpen else { return }  // closed on purpose
        emit(.closed(error.map(describe) ?? (wasReady ? "The camera's Bluetooth link dropped." : "The camera hung up.")))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            emit(.closed(error?.localizedDescription ?? "The camera's Bluetooth services weren't found."))
            return
        }
        guard services.contains(where: { $0.uuid == Self.cameraService }) else {
            emit(.closed("That isn't a Blackmagic camera: it has no camera control service."))
            return
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        if service.uuid == Self.cameraService { characteristicsFound() }
        if service.uuid == Self.deviceInformation, let modelNumber = characteristics[Self.modelNumber] {
            peripheral.readValue(for: modelNumber)  // not encrypted
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            guard isAuthenticationError(error) else {
                emit(.closed("The camera refused Tiles' subscription: \(describe(error))"))
                return
            }
            // Not bonded yet: the system is asking for the camera's code. Ask again shortly; it finishes the bond.
            emit(.pairing)
            retry?.cancel()
            let again = DispatchWorkItem { [weak self] in
                guard let self, self.wantsOpen, !self.ready else { return }
                for uuid in Self.notifying where !self.subscribed.contains(uuid) { self.subscribe(uuid) }
            }
            retry = again
            queue.asyncAfter(deadline: .now() + 4, execute: again)
            return
        }
        if characteristic.isNotifying { subscribed.insert(characteristic.uuid) }
        becameReady()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if isAuthenticationError(error) { emit(.pairing) }
            return
        }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.modelNumber:
            model = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            if ready { emit(.ready(model: model)) }  // the name came after the link was up
        case Self.incoming:
            emit(.incoming(value))
        case Self.timecode where value.count >= 4:
            // A 32-bit BCD number, little-endian as Bluetooth sends integers (to be confirmed on a camera).
            emit(.timecode(value.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
        case Self.status where !value.isEmpty:
            emit(.status(BlackmagicBluetooth.Status(rawValue: value[value.startIndex])))
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.outgoing, !writes.isEmpty else { return }
        let done = writes.removeFirst().done
        if let error { done.resume(throwing: BluetoothLinkError.writeFailed(error.localizedDescription)) } else { done.resume() }
    }
}
#endif

