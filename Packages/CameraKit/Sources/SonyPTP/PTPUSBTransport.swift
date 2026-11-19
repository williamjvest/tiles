// PTP over USB (USB Still Image Capture Device Definition; PIMA 15740 containers), for a Sony camera cabled to a Mac
// in USB Connection Mode → Remote Shooting. The same Sony PC Remote protocol as PTP-IP, carried in bulk containers:
// command out, an optional data phase either way, the response in; events arrive on the interrupt pipe.
//
// The camera presents one PTP interface (class 6/1/1): bulk out, bulk in, interrupt in. Checked on an FX3
// (054c:0da3): every SDIO op answers in a few ms; live view runs at ~23 fps.

import Foundation

// MARK: - Containers

/// One PTP USB container: length (UINT32, header included), type, operation/response/event code, transaction ID,
/// then parameters (command, response, event) or data.
public struct PTPUSBContainer: Sendable, Equatable {
    public enum Kind: UInt16, Sendable {
        case command = 1, data = 2, response = 3, event = 4
    }
    public static let headerSize = 12

    public var kind: Kind
    public var code: UInt16
    public var transactionID: UInt32
    public var payload: Data

    public init(kind: Kind, code: UInt16, transactionID: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.code = code
        self.transactionID = transactionID
        self.payload = payload
    }

    public init(kind: Kind, code: UInt16, transactionID: UInt32, params: [UInt32]) {
        var payload = Data()
        for param in params { payload.appendLE(param) }
        self.init(kind: kind, code: code, transactionID: transactionID, payload: payload)
    }

    /// Parameters, for a command, response or event.
    public var params: [UInt32] {
        stride(from: 0, through: payload.count - 4, by: 4).map { payload.readLE(UInt32.self, at: $0) }
    }

    public var encoded: Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.appendLE(UInt32(Self.headerSize + payload.count))
        out.appendLE(kind.rawValue)
        out.appendLE(code)
        out.appendLE(transactionID)
        out.append(payload)
        return out
    }
}

/// Puts containers back together from what a pipe returns. A container longer than one read arrives over several,
/// and one read can end a container and hold the next. An empty read is a zero-length packet a device sends after a
/// container that filled its last packet, and adds nothing.
struct PTPUSBContainerAssembler {
    private var pending = Data()

    /// Adds one read; returns the first container it completes (`next()` gives any after it).
    mutating func add(_ chunk: Data) throws -> PTPUSBContainer? {
        pending.append(chunk)
        return try next()
    }

    /// The next whole container already read, if there is one.
    mutating func next() throws -> PTPUSBContainer? {
        guard pending.count >= PTPUSBContainer.headerSize else { return nil }
        let length = Int(pending.readLE(UInt32.self, at: 0))
        guard length >= PTPUSBContainer.headerSize,
              let kind = PTPUSBContainer.Kind(rawValue: pending.readLE(UInt16.self, at: 4)) else {
            pending = Data()
            throw PTPError.unexpectedPacket("USB container header")
        }
        guard pending.count >= length else { return nil }
        let container = PTPUSBContainer(kind: kind, code: pending.readLE(UInt16.self, at: 6),
                                        transactionID: pending.readLE(UInt32.self, at: 8),
                                        payload: Data(pending[PTPUSBContainer.headerSize..<length]))
        pending = Data(pending[length...])
        return container
    }
}

#if os(macOS)
import CameraCore
import IOKit
import IOKit.usb

public struct PTPUSBTransportConfig: Sendable {
    /// Waiting for a container from the camera: a slow operation's response included.
    public var transactionTimeout: TimeInterval = 30
    /// Sending a container to the camera.
    public var sendTimeout: TimeInterval = 5
    public init() {}
}

public enum PTPUSBError: LocalizedError, Equatable {
    case notPluggedIn
    case notRemoteShooting
    case inUse
    case noPipes
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notPluggedIn: "Not plugged in by USB"
        case .notRemoteShooting: "Set the camera's USB Connection Mode to Remote Shooting"
        case .inUse: "Another app has the camera's USB connection (Image Capture, Imaging Edge?)"
        case .noPipes: "The camera's USB interface isn't the one expected"
        case .io(let message): "USB: \(message)"
        }
    }
}

/// One USB interface, opened through IOKit's USB plug-in (IOUSBInterfaceInterface). That is what the App Sandbox's USB
/// entitlement lets an app open: the IOUSBHost framework's user client is refused there (kIOReturnNotPermitted, seen on
/// macOS 26). Calls block; the COM object is released only when the last reference goes, so a call racing a close
/// gets an error back, not a freed object.
final class USBInterface: @unchecked Sendable {
    struct Pipe {
        let ref: UInt8
        let isIn: Bool
        /// 2 bulk, 3 interrupt.
        let transferType: UInt8
        let maxPacketSize: Int
    }

    /// An IOReturn from a call, with what was being done.
    struct Failure: LocalizedError {
        let what: String
        let code: IOReturn
        /// kIOReturnNoDevice, kIOReturnNotResponding: the cable or the camera went.
        var isUnplugged: Bool { [0xE000_02C0, 0xE000_02ED].contains(UInt32(bitPattern: code)) }
        var errorDescription: String? {
            isUnplugged ? "Unplugged" : "USB: \(what) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        }
    }

    private typealias Handle = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface942>>
    private let handle: Handle
    private let lock = NSLock()
    private var closed = false
    private var vtable: IOUSBInterfaceInterface942 { handle.pointee.pointee }

    /// Opens the interface, exclusively: another process holding it gives `PTPUSBError.inUse`.
    init(service: io_service_t) throws {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(service, Self.interfaceUserClientType, Self.plugInInterface,
                                                        &plugin, &score)
        guard created == KERN_SUCCESS, let plugin, let plugInVtable = plugin.pointee?.pointee else {
            throw Failure(what: "the camera's USB interface wouldn't open", code: created)
        }
        defer { _ = plugInVtable.Release(plugin) }
        var raw: LPVOID?
        guard plugInVtable.QueryInterface(plugin, CFUUIDGetUUIDBytes(Self.interfaceInterface), &raw) == 0, let raw else {
            throw PTPUSBError.io("the camera's USB interface has no plug-in")
        }
        handle = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBInterfaceInterface942>.self)
        let opened = handle.pointee.pointee.USBInterfaceOpen(handle)
        guard opened == KERN_SUCCESS else {
            _ = handle.pointee.pointee.Release(handle)
            if UInt32(bitPattern: opened) == 0xE000_02C5 { throw PTPUSBError.inUse }  // kIOReturnExclusiveAccess
            throw Failure(what: "the camera's USB interface wouldn't open", code: opened)
        }
    }

    deinit {
        if !closed { _ = vtable.USBInterfaceClose(handle) }
        _ = vtable.Release(handle)
    }

    func pipes() throws -> [Pipe] {
        var count: UInt8 = 0
        let listed = vtable.GetNumEndpoints(handle, &count)
        guard listed == KERN_SUCCESS else { throw Failure(what: "couldn't list the camera's USB pipes", code: listed) }
        guard count > 0 else { return [] }
        return (1...count).compactMap { ref in
            var direction: UInt8 = 0, number: UInt8 = 0, type: UInt8 = 0, interval: UInt8 = 0, maxPacket: UInt16 = 0
            guard vtable.GetPipeProperties(handle, ref, &direction, &number, &type, &maxPacket, &interval) == KERN_SUCCESS
            else { return nil }
            return Pipe(ref: ref, isIn: direction == 1, transferType: type, maxPacketSize: Int(maxPacket))
        }
    }

    func clearStall(_ pipe: UInt8) {
        _ = vtable.ClearPipeStallBothEnds(handle, pipe)
    }

    /// The PTP class's Device Reset Request (0x66): the camera drops whatever transaction it was in. Pipes are cleared
    /// after it.
    func resetPTP() {
        var number: UInt8 = 0
        _ = vtable.GetInterfaceNumber(handle, &number)
        var request = IOUSBDevRequestTO(bmRequestType: 0x21, bRequest: 0x66, wValue: 0, wIndex: UInt16(number), wLength: 0,
                                        pData: nil, wLenDone: 0, noDataTimeout: 2000, completionTimeout: 2000)
        _ = vtable.ControlRequestTO(handle, 0, &request)
        var count: UInt8 = 0
        if vtable.GetNumEndpoints(handle, &count) == KERN_SUCCESS, count > 0 {
            for ref in 1...count { clearStall(ref) }
        }
    }

    /// Writes `count` bytes; none sends a zero-length packet.
    func write(_ pipe: UInt8, _ bytes: UnsafeRawPointer?, count: Int, timeout: TimeInterval) throws {
        var none: UInt8 = 0
        let ms = UInt32(timeout * 1000)
        let sent = withUnsafeMutablePointer(to: &none) { fallback in
            vtable.WritePipeTO(handle, pipe, UnsafeMutableRawPointer(mutating: bytes) ?? UnsafeMutableRawPointer(fallback),
                               UInt32(count), ms, ms)
        }
        guard sent == KERN_SUCCESS else { throw Failure(what: "send failed", code: sent) }
    }

    /// Reads up to `capacity` bytes. A timeout of zero waits as long as it takes, the only kind an interrupt pipe allows.
    func read(_ pipe: UInt8, into buffer: UnsafeMutableRawPointer, capacity: Int, timeout: TimeInterval) throws -> Int {
        var size = UInt32(capacity)
        let ms = UInt32(timeout * 1000)
        let read = timeout > 0 ? vtable.ReadPipeTO(handle, pipe, buffer, &size, ms, ms) : vtable.ReadPipe(handle, pipe, buffer, &size)
        guard read == KERN_SUCCESS else { throw Failure(what: "read failed", code: read) }
        return Int(size)
    }

    /// Aborts what's pending on every pipe, then closes. Calls after this fail.
    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        var count: UInt8 = 0
        if vtable.GetNumEndpoints(handle, &count) == KERN_SUCCESS, count > 0 {
            for ref in 1...count { _ = vtable.AbortPipe(handle, ref) }
        }
        _ = vtable.USBInterfaceClose(handle)
    }

    // kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, kIOUSBInterfaceInterfaceID942: macros Swift doesn't see.
    private static var interfaceUserClientType: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
                                       0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    }
    private static var plugInInterface: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                       0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    private static var interfaceInterface: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, 0x87, 0x52, 0x66, 0x3B, 0xC0, 0x7B, 0x4B, 0xAE,
                                       0x95, 0x84, 0x22, 0x03, 0x2F, 0xAB, 0x9C, 0x5A)
    }
}

/// PTP over USB to one camera, found by its USB serial number. Any transfer that fails fails the whole link: USB has
/// no connection to close and reopen mid-transaction, so the backend's reconnect starts clean instead.
public final class PTPUSBTransport: PTPTransport, @unchecked Sendable {
    public var onStateChange: (@Sendable (PTPTransportState) -> Void)?
    public var onEvent: (@Sendable (ParsedEvent) -> Void)?

    private let serial: String
    private let config: PTPUSBTransportConfig
    private let gate = TransactionGate()
    private let lock = NSLock()
    /// Bulk transfers block: they run here, one at a time, off the cooperative thread pool.
    private let io = DispatchQueue(label: "sony-ptp.usb.io")
    /// Bulk-in reads land here; only touched on `io`.
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: PTPUSBTransport.readCapacity, alignment: 16)
    private static let readCapacity = 1 << 20
    private var _state: PTPTransportState = .idle
    private var link: Link?
    private var transactionID: UInt32 = 0

    private struct Link {
        let usb: USBInterface
        let bulkOut: UInt8
        let bulkIn: UInt8
        let interrupt: USBInterface.Pipe?
        let maxPacketOut: Int
        /// Fails the link the moment the camera goes (cable pulled, switched off), idle or not.
        let removal: IOKitNotification?

        /// Closes the interface, which aborts what's pending on it: off the caller's thread, which may be the main
        /// one, where the removal notice arrives.
        func release() {
            DispatchQueue.global().async { [usb] in usb.close() }
        }
    }

    public init(serial: String, config: PTPUSBTransportConfig = PTPUSBTransportConfig()) {
        self.serial = serial
        self.config = config
    }

    deinit {
        link?.release()
        readBuffer.deallocate()
    }

    public var state: PTPTransportState { lock.withLock { _state } }

    // MARK: Link

    /// Opens the camera's PTP interface and its pipes. The interface opens exclusively: another app holding it is
    /// reported as such.
    public func connect() async throws {
        setState(.connecting)
        do {
            let service = try Self.ptpInterface(serial: serial)
            defer { IOObjectRelease(service) }
            let usb = try USBInterface(service: service)
            let pipes = try usb.pipes()
            guard let bulkOut = pipes.first(where: { $0.transferType == 2 && !$0.isIn }),
                  let bulkIn = pipes.first(where: { $0.transferType == 2 && $0.isIn }) else {
                usb.close()
                throw PTPUSBError.noPipes
            }
            // A previous controller may have left a pipe halted.
            usb.clearStall(bulkOut.ref)
            usb.clearStall(bulkIn.ref)
            let link = Link(usb: usb, bulkOut: bulkOut.ref, bulkIn: bulkIn.ref,
                            interrupt: pipes.first { $0.transferType == 3 && $0.isIn },
                            maxPacketOut: max(bulkOut.maxPacketSize, 1),
                            removal: IOKitNotification.removal(of: service) { [weak self] in self?.linkLost("Unplugged") })
            do {
                try await onIO { try self.probe(link) }
            } catch {
                usb.close()
                throw error
            }
            lock.withLock { self.link = link }
            setState(.connected)
        } catch {
            setState(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            throw error
        }
    }

    public func startReceiving() {
        guard let link = lock.withLock({ self.link }), let interrupt = link.interrupt else { return }
        // Reads of one packet: a read only ends early on a short packet, so a bigger one would hold an event that
        // filled its last packet until the next event arrived.
        let capacity = max(interrupt.maxPacketSize, 8)
        // One event read always armed, on its own thread since it blocks; it ends when the link goes.
        Thread.detachNewThread { [weak self] in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            defer { buffer.deallocate() }
            var assembler = PTPUSBContainerAssembler()
            while let self, self.state == .connected {
                let bytes: Int
                do {
                    bytes = try link.usb.read(interrupt.ref, into: buffer, capacity: capacity, timeout: 0)
                } catch {
                    self.linkLost((error as? LocalizedError)?.errorDescription ?? "\(error)")  // a no-op once the link has gone
                    return
                }
                var container = try? assembler.add(Data(bytes: buffer, count: bytes))
                while let event = container {
                    if event.kind == .event {
                        self.onEvent?(ParsedEvent(eventCode: event.code, transactionID: event.transactionID, params: event.params))
                    }
                    container = try? assembler.next()
                }
            }
        }
    }

    public func disconnect() async {
        let link = lock.withLock { () -> Link? in
            defer { self.link = nil }
            return self.link
        }
        link?.release()  // the event read included
        setState(.disconnected)
    }

    // MARK: Transactions

    public func execute(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data) {
        try await gate.run { [self] in
            try await self.transact(opCode: opCode, params: params, sendData: sendData)
        }
    }

    private func transact(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data) {
        guard let link = lock.withLock({ self.link }), state == .connected else { throw PTPError.disconnected }
        let id = lock.withLock { () -> UInt32 in
            transactionID &+= 1
            return transactionID
        }
        do {
            return try await onIO { [self] in
                try self.write(PTPUSBContainer(kind: .command, code: opCode, transactionID: id, params: params).encoded, link)
                if let sendData {
                    try self.write(PTPUSBContainer(kind: .data, code: opCode, transactionID: id, payload: sendData).encoded, link)
                }
                var assembler = PTPUSBContainerAssembler()
                var dataIn = Data()
                while true {
                    let container: PTPUSBContainer
                    if let buffered = try assembler.next() {
                        container = buffered
                    } else if let completed = try assembler.add(try self.read(link)) {
                        container = completed
                    } else {
                        continue
                    }
                    switch container.kind {
                    case .data:
                        dataIn = container.payload
                    case .response:
                        return (ParsedCmdResponse(responseCode: container.code, transactionID: container.transactionID,
                                                  params: container.params), dataIn)
                    case .command, .event:
                        throw PTPError.unexpectedPacket("USB container \(container.kind) on bulk in")
                    }
                }
            }
        } catch {
            linkLost((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    /// Asks for the device info, outside any session, to prove the camera is taking commands. One that isn't (seen
    /// on an FX3 after another program's session ended mid-transaction: every send timed out) gets a PTP device reset
    /// and is asked again.
    private func probe(_ link: Link) throws {
        do {
            try askDeviceInfo(link)
        } catch {
            link.usb.resetPTP()
            try askDeviceInfo(link)
        }
    }

    private func askDeviceInfo(_ link: Link) throws {
        let timeout: TimeInterval = 2
        let command = PTPUSBContainer(kind: .command, code: PTPOpCode.getDeviceInfo.rawValue, transactionID: 0, params: []).encoded
        try command.withUnsafeBytes { bytes in
            try link.usb.write(link.bulkOut, bytes.baseAddress, count: command.count, timeout: timeout)
        }
        var assembler = PTPUSBContainerAssembler()
        while true {
            let bytes = try link.usb.read(link.bulkIn, into: readBuffer, capacity: Self.readCapacity, timeout: timeout)
            var container = try assembler.add(Data(bytes: readBuffer, count: bytes))
            while let received = container {
                if received.kind == .response { return }
                container = try assembler.next()
            }
        }
    }

    /// Runs blocking USB calls on the I/O queue.
    private func onIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// One container out; a zero-length packet after one that fills its last packet, so the camera sees it end.
    private func write(_ data: Data, _ link: Link) throws {
        try data.withUnsafeBytes { bytes in
            try link.usb.write(link.bulkOut, bytes.baseAddress, count: data.count, timeout: config.sendTimeout)
        }
        if data.count % link.maxPacketOut == 0 {
            try link.usb.write(link.bulkOut, nil, count: 0, timeout: config.sendTimeout)
        }
    }

    private func read(_ link: Link) throws -> Data {
        let bytes = try link.usb.read(link.bulkIn, into: readBuffer, capacity: Self.readCapacity,
                                      timeout: config.transactionTimeout)
        return Data(bytes: readBuffer, count: bytes)
    }

    // MARK: State

    private func linkLost(_ reason: String) {
        let link = lock.withLock { () -> Link? in
            defer { self.link = nil }
            return self.link
        }
        guard let link else { return }
        setState(.failed(reason))
        link.release()
    }

    private func setState(_ newState: PTPTransportState) {
        let changed = lock.withLock { () -> Bool in
            guard _state != newState else { return false }
            _state = newState
            return true
        }
        if changed { onStateChange?(newState) }
    }

    // MARK: Finding the camera

    /// Sony's USB vendor ID.
    static let sonyVendorID = 0x054C

    /// The PTP interface (class 6) of the Sony camera with this serial number. Throws `.notRemoteShooting` when the
    /// camera is cabled but in another USB mode (mass storage, MTP), `.notPluggedIn` when it isn't there.
    static func ptpInterface(serial: String) throws -> io_service_t {
        if let service = firstService("IOUSBHostInterface", ["idVendor": sonyVendorID, "bInterfaceClass": 6], serial: serial) {
            return service
        }
        if let device = firstService("IOUSBHostDevice", ["idVendor": sonyVendorID], serial: serial) {
            IOObjectRelease(device)
            throw PTPUSBError.notRemoteShooting
        }
        throw PTPUSBError.notPluggedIn
    }

    /// The entry of the camera with this serial number, retained for the caller to release.
    private static func firstService(_ className: String, _ properties: [String: Int], serial: String) -> io_service_t? {
        let found = USBRegistry.entries(className, where: properties) { service -> io_service_t? in
            guard USBRegistry.string("USB Serial Number", of: service) == serial else { return nil }
            IOObjectRetain(service)
            return service
        }
        found.dropFirst().forEach { IOObjectRelease($0) }
        return found.first
    }
}
#endif
