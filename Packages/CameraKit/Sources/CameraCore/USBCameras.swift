import Foundation

// MARK: - A camera on USB

/// A camera on a USB cable is saved with a host of the form `usb:<serial>`: unique per camera, so two bodies of the
/// same model don't collide, and it finds the same camera whichever port it's in.
public enum USBCameraAddress {
    public static let scheme = "usb:"

    public static func host(serial: String) -> String { scheme + serial }

    /// The USB serial number, when `host` is a USB camera's.
    public static func serial(in host: String) -> String? {
        guard host.hasPrefix(scheme) else { return nil }
        let serial = String(host.dropFirst(scheme.count))
        return serial.isEmpty ? nil : serial
    }

    /// A serial number to show: a long one (a Blackmagic camera's has 32 characters) by its ends.
    public static func label(serial: String) -> String {
        serial.count > 12 ? "\(serial.prefix(4))…\(serial.suffix(4))" : serial
    }

    /// How a host reads in a list: "USB" for a camera on a cable, "Bluetooth" for one over the air, the address otherwise.
    public static func display(_ host: String) -> String {
        if BluetoothCameraAddress.id(in: host) != nil { return "Bluetooth" }
        return serial(in: host) == nil ? host : "USB"
    }
}

#if os(macOS)
import IOKit

/// Reads USB devices from the IORegistry. The USB family's own matching takes only certain key combinations
/// (`idVendor` alone, or with `bInterfaceClass`, matches nothing), so entries are found by class and their
/// properties compared here.
public enum USBRegistry {
    /// What `read` returns for every entry of `className` whose numeric properties equal `wanted`. Each entry is
    /// released after `read`; retain it there to keep it.
    public static func entries<T>(_ className: String, where wanted: [String: Int],
                                  read: (io_service_t) -> T?) -> [T] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [T] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard wanted.allSatisfy({ number($0.key, of: service) == $0.value }), let value = read(service) else { continue }
            found.append(value)
        }
        return found
    }

    public static func number(_ key: String, of service: io_service_t) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    /// A string property of the entry or, failing that, of the device it belongs to.
    public static func string(_ key: String, of service: io_service_t) -> String? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
    }

    /// A string property of the entry or of an entry under it, e.g. the BSD name of the network interface under a USB
    /// device.
    public static func string(_ key: String, below service: io_service_t) -> String? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively)) as? String
    }
}

/// A Sony camera on this Mac's USB, as the IORegistry lists it.
public struct USBCamera: Sendable, Equatable, Identifiable {
    public var serial: String
    /// The camera's USB product name, e.g. "ILME-FX3".
    public var product: String
    /// It presents a PTP interface: USB Connection Mode is Remote Shooting. Otherwise it's in mass storage or MTP.
    public var isRemoteShooting: Bool
    public var id: String { serial }
    public var host: String { USBCameraAddress.host(serial: serial) }

    public init(serial: String, product: String, isRemoteShooting: Bool) {
        self.serial = serial
        self.product = product
        self.isRemoteShooting = isRemoteShooting
    }

    /// Sony's USB vendor ID.
    static let sonyVendorID = 0x054C

    /// Every Sony camera on USB now. Reads the IORegistry only: nothing is opened.
    public static func connected() -> [USBCamera] {
        let serial = { (service: io_service_t) in USBRegistry.string("USB Serial Number", of: service).flatMap { $0.isEmpty ? nil : $0 } }
        let ptpSerials = Set(USBRegistry.entries("IOUSBHostInterface", where: ["idVendor": sonyVendorID, "bInterfaceClass": 6],
                                                 read: serial))
        return USBRegistry.entries("IOUSBHostDevice", where: ["idVendor": sonyVendorID]) { service -> USBCamera? in
            guard let serial = serial(service) else { return nil }
            return USBCamera(serial: serial, product: USBRegistry.string("USB Product Name", of: service) ?? "Sony camera",
                             isRemoteShooting: ptpSerials.contains(serial))
        }
        .sorted { $0.product == $1.product ? $0.serial < $1.serial : $0.product < $1.product }
    }
}
#endif

// MARK: - Watching USB

#if os(macOS)
/// One IOKit notification, delivered on the main queue for as long as this is kept.
public final class IOKitNotification: @unchecked Sendable {
    private final class Handler {
        let call: (io_iterator_t, UInt32) -> Void
        init(_ call: @escaping (io_iterator_t, UInt32) -> Void) { self.call = call }
    }

    private let port: IONotificationPortRef
    private let handler: Unmanaged<Handler>
    private var object: io_object_t = 0

    private init(_ call: @escaping (io_iterator_t, UInt32) -> Void) {
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        handler = Unmanaged.passRetained(Handler(call))
    }

    deinit {
        // On the main queue, where the callbacks run: none is running during it, and none comes after it.
        let teardown = Teardown(port: port, object: object, handler: handler)
        DispatchQueue.main.async { teardown.run() }
    }

    private struct Teardown: @unchecked Sendable {
        let port: IONotificationPortRef
        let object: io_object_t
        let handler: Unmanaged<Handler>

        func run() {
            IOObjectRelease(object)
            IONotificationPortDestroy(port)
            handler.release()
        }
    }

    /// `service` going away: its cable pulled, or the device switched off.
    public static func removal(of service: io_service_t, _ removed: @escaping () -> Void) -> IOKitNotification? {
        let notification = IOKitNotification { _, message in
            if message == 0xE000_0010 { removed() }  // kIOMessageServiceIsTerminated
        }
        let added = IOServiceAddInterestNotification(notification.port, service, kIOGeneralInterest, { refcon, _, message, _ in
            guard let refcon else { return }
            Unmanaged<Handler>.fromOpaque(refcon).takeUnretainedValue().call(0, message)
        }, notification.handler.toOpaque(), &notification.object)
        return added == KERN_SUCCESS ? notification : nil
    }

    /// Each registry entry of `className` that appears from now on, given to `appeared`, which mustn't keep it.
    public static func arrivals(of className: String, _ appeared: @escaping (io_service_t) -> Void) -> IOKitNotification? {
        let drain = { (iterator: io_iterator_t) in
            while case let service = IOIteratorNext(iterator), service != 0 {
                appeared(service)
                IOObjectRelease(service)
            }
        }
        let notification = IOKitNotification { iterator, _ in drain(iterator) }
        let added = IOServiceAddMatchingNotification(notification.port, kIOFirstMatchNotification, IOServiceMatching(className),
                                                     { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<Handler>.fromOpaque(refcon).takeUnretainedValue().call(iterator, 0)
        }, notification.handler.toOpaque(), &notification.object)
        guard added == KERN_SUCCESS else { return nil }
        // Arms it. The entries there already haven't just appeared.
        while case let service = IOIteratorNext(notification.object), service != 0 { IOObjectRelease(service) }
        return notification
    }
}
#endif

#if os(iOS) && canImport(ImageCaptureCore)
import ImageCaptureCore
#endif

/// Says when a camera is plugged in by USB, with its address, so one that was unplugged reconnects as it comes back
/// instead of on its next retry.
@MainActor
public final class USBCameraArrivals {
    private let arrived: @MainActor (String) -> Void
    #if os(macOS)
    private var sony: IOKitNotification?
    private var blackmagic: IOKitNotification?
    #else
    private var blackmagicWatch: UUID?
    #endif
    #if os(iOS) && canImport(ImageCaptureCore)
    private var browser: ICDeviceBrowser?
    private var finder: Finder?
    #endif

    public init(_ arrived: @escaping @MainActor (String) -> Void) {
        self.arrived = arrived
    }

    deinit {
        #if !os(macOS)
        if let blackmagicWatch { BlackmagicAdverts.shared.stopWatching(blackmagicWatch) }
        #endif
    }

    /// Starts watching, what it isn't yet: Sony cameras, and Blackmagic ones when `blackmagic`. On iPhone and iPad a
    /// Sony camera only once Tiles may control cameras (this never asks), and a Blackmagic one by its Bonjour advert.
    public func start(blackmagic: Bool) {
        startSony()
        if blackmagic { startBlackmagic() }
    }

    private func startSony() {
        #if os(macOS)
        guard sony == nil else { return }
        // Once it presents its PTP interface, in Remote Shooting.
        sony = IOKitNotification.arrivals(of: "IOUSBHostInterface") { [weak self] service in
            guard USBRegistry.number("idVendor", of: service) == USBCamera.sonyVendorID,
                  USBRegistry.number("bInterfaceClass", of: service) == 6,
                  let serial = USBRegistry.string("USB Serial Number", of: service) else { return }
            MainActor.assumeIsolated { self?.arrived(USBCameraAddress.host(serial: serial)) }
        }
        #elseif os(iOS) && canImport(ImageCaptureCore)
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        guard browser.controlAuthorizationStatus == .authorized else { return }
        // Cameras already plugged in are announced too: one of them that's down gets a reconnect, which is harmless.
        let finder = Finder { [weak self] name in self?.arrived(USBCameraAddress.host(serial: name)) }
        browser.delegate = finder
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        self.browser = browser
        self.finder = finder
        #endif
    }

    private func startBlackmagic() {
        #if os(macOS)
        guard blackmagic == nil else { return }
        // As soon as it's on the bus. Its link comes up a few seconds later, and its connect waits for that.
        blackmagic = IOKitNotification.arrivals(of: "IOUSBHostDevice") { [weak self] service in
            guard USBRegistry.number("idVendor", of: service) == BlackmagicUSBCamera.vendorID,
                  let serial = USBRegistry.string("USB Serial Number", of: service), !serial.isEmpty else { return }
            let host = USBCameraAddress.host(serial: BlackmagicUSBSerial.normalised(serial))
            MainActor.assumeIsolated { self?.arrived(host) }
        }
        #else
        // When its advert comes over a cable, which is once its link is up.
        guard blackmagicWatch == nil else { return }
        blackmagicWatch = BlackmagicAdverts.shared.watch { [weak self] advert in
            guard advert.mayBeCable || BlackmagicAdverts.onHotspot(advert, among: LocalAddresses.ipv4ByInterface()) else { return }
            Task { @MainActor in self?.arrived(advert.host) }
        }
        BlackmagicAdverts.shared.start()
        #endif
    }

    #if os(iOS) && canImport(ImageCaptureCore)
    private final class Finder: NSObject, ICDeviceBrowserDelegate {
        let found: @MainActor (String) -> Void
        init(_ found: @escaping @MainActor (String) -> Void) { self.found = found }

        func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
            guard device is ICCameraDevice, let name = device.name else { return }
            let found = self.found
            MainActor.assumeIsolated { found(name) }
        }
        func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    }
    #endif
}
