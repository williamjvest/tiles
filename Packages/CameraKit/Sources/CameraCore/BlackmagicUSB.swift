import Foundation

// MARK: - A Blackmagic camera on USB

/// A Blackmagic camera's USB-C cable is a network link. The camera hands this device an address on it and serves its
/// REST API there, and Remote Control on port 444, just as on a network. Its address on the cable isn't saved: the
/// camera is saved as `usb:<serial>` (`USBCameraAddress`) and found on its cable at each connect (`BlackmagicUSBLink`).
/// The serial is its USB serial number, which is also the `unique id` it advertises over Bonjour: a Mac finds the
/// camera by its USB device, an iPhone or iPad by its advert (`BlackmagicAdverts`).
public enum BlackmagicUSBSerial {
    /// A serial as it's saved: in lower case, as USB gives it (Bonjour gives the same in capitals).
    public static func normalised(_ serial: String) -> String { serial.lowercased() }
}

/// Where a Blackmagic camera on a USB cable answers. The cable's link has two addresses, the camera's and this
/// device's: a /30, with no router, and the camera handing this device its address (172.27.250.13 and .14 on a
/// PYXIS 12K, Camera 10.3.1). The camera has no IPv6 address there. So the camera is the other address of the pair
/// this device has on the cable's interface.
public enum BlackmagicUSBLink {
    /// Why the camera can't be reached on its cable. Each says what to do, as a connection failure does.
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case notConnected
        case linkNotUp
        /// Another interface here has the same addresses. A request then leaves by one of the two, and which isn't up
        /// to Tiles: two cameras of one model hand out the same pair.
        case sharedAddresses
        /// Not a two-address link, so the camera's address on it can't be told.
        case unknownLink

        public var description: String {
            #if os(macOS)
            let here = "this Mac's USB"
            #else
            let here = "this device's USB-C"
            #endif
            return switch self {
            case .notConnected: "The camera isn't on \(here): connect it with a USB-C cable"
            case .linkNotUp: "The camera is on USB but its link didn't come up: check it's on, or plug the cable in again"
            case .sharedAddresses:
                "Another camera on \(here) has the same address, so Tiles can't tell which it reaches: unplug one"
            case .unknownLink: "The camera's USB link isn't one Tiles can find it on: use its network address instead"
            }
        }
    }

    /// What one look finds.
    public enum Finding: Equatable, Sendable {
        /// The camera's IPv4 address.
        case at(String)
        /// On the cable, its link still coming up: a second or two after the cable goes in.
        case starting
        case problem(Problem)
    }

    /// The camera on `interface` (nil: its interface isn't there yet), from this device's IPv4 addresses.
    public static func find(on interface: String?, among addresses: [LocalIPv4]) -> Finding {
        // A self-assigned 169.254 address is what the interface has while it waits for the camera's.
        guard let interface,
              let link = addresses.first(where: { $0.interface == interface && !$0.isSelfAssigned }) else { return .starting }
        guard let camera = link.peer else { return .problem(.unknownLink) }
        let network = link.address & link.netmask
        if addresses.contains(where: { $0.interface != interface && $0.address & link.netmask == network }) {
            return .problem(.sharedAddresses)
        }
        return .at(LocalIPv4.dotted(camera))
    }

    /// Whether `interface` is a cable's link: this device has one of a two-address pair there, given to it.
    public static func isCable(_ interface: String, among addresses: [LocalIPv4]) -> Bool {
        addresses.contains { $0.interface == interface && !$0.isSelfAssigned && $0.peer != nil }
    }

    /// The camera with `serial` from its Bonjour adverts, as an iPhone or iPad finds it: one on a wired interface,
    /// found there as on a Mac, or one on this iPhone's Personal Hotspot, at the address its advert resolved to
    /// (`resolved`, by `BlackmagicAdverts.key`; still being asked for: starting). Not seen yet while the browse is
    /// young, as a camera's link takes a few seconds to come up after the cable goes in (4.5 s on a PYXIS 12K); not
    /// there after that.
    public static func find(serial: String, adverts: [BlackmagicAdverts.Advert], lookingFor: Duration,
                            among addresses: [LocalIPv4], resolved: [String: String] = [:]) -> Finding {
        let serial = BlackmagicUSBSerial.normalised(serial)
        let mine = adverts.filter { $0.serial == serial }
        let hotspot = mine.filter { BlackmagicAdverts.onHotspot($0, among: addresses) }
        let wired = mine.filter { $0.mayBeCable && !hotspot.contains($0) }
        let findings = wired.map { find(on: $0.interface, among: addresses) }
            + hotspot.map { resolved[BlackmagicAdverts.key($0)].map(Finding.at) ?? .starting }
        guard !findings.isEmpty else { return lookingFor < .seconds(6) ? .starting : .problem(.notConnected) }
        return findings.first { if case .at = $0 { true } else { false } }
            ?? findings.first { $0 == .starting } ?? findings[0]
    }

    #if os(macOS)
    /// One look for the camera with `serial` on this Mac's USB.
    public static func find(serial: String) -> Finding {
        let serial = BlackmagicUSBSerial.normalised(serial)
        guard let device = BlackmagicUSBCamera.devices().first(where: { $0.serial == serial }) else {
            return .problem(.notConnected)
        }
        return find(on: device.interface, among: LocalAddresses.ipv4ByInterface())
    }
    #endif

    /// The camera's address on its cable, waiting up to `patience` while its link comes up. Throws the `Problem`.
    /// A Mac looks at its USB devices; an iPhone or iPad at the cameras' Bonjour adverts.
    public static func address(serial: String, patience: Duration = .seconds(10)) async throws -> String {
        #if os(macOS)
        try await waitForAddress(patience: patience) { find(serial: serial) }
        #else
        try await addressFromAdverts(serial: serial, patience: patience)
        #endif
    }

    /// `address` as an iPhone or iPad finds it, through the cameras' Bonjour adverts; there on a Mac too, for checking.
    public static func addressFromAdverts(serial: String, patience: Duration = .seconds(10)) async throws -> String {
        let adverts = BlackmagicAdverts.shared
        adverts.start()
        do {
            return try await waitForAddress(patience: patience) {
                let addresses = LocalAddresses.ipv4ByInterface()
                adverts.resolveHotspotAdverts(among: addresses)
                return find(serial: serial, adverts: adverts.adverts, lookingFor: adverts.lookingFor, among: addresses,
                            resolved: adverts.resolved)
            }
        } catch {
            // Which step it failed at: no advert, an advert on a link that isn't a cable's, or no address there.
            ActivityLog.shared.note(USBCameraAddress.host(serial: serial), "not found on its cable: \(adverts.describe())")
            throw error
        }
    }

    /// Looks every `interval` until `look` finds the camera or a problem, or `patience` runs out while its link is
    /// still coming up.
    static func waitForAddress(patience: Duration, interval: Duration = .milliseconds(200),
                               _ look: () -> Finding) async throws -> String {
        let deadline = ContinuousClock.now + patience
        while true {
            switch look() {
            case .at(let address): return address
            case .problem(let problem): throw problem
            case .starting:
                guard ContinuousClock.now < deadline else { throw Problem.linkNotUp }
                try await Task.sleep(for: interval)
            }
        }
    }
}

// MARK: - This device's addresses, by interface

/// One of this device's IPv4 addresses, with its interface and netmask.
public struct LocalIPv4: Equatable, Sendable {
    public var interface: String
    public var address: UInt32
    public var netmask: UInt32

    public init(interface: String, address: UInt32, netmask: UInt32) {
        self.interface = interface
        self.address = address
        self.netmask = netmask
    }

    /// From a dotted address and its prefix length, e.g. `("en14", "172.27.250.14", 30)`.
    public init?(interface: String, _ dotted: String, prefix: Int) {
        guard let address = Self.value(dotted), (0 ... 32).contains(prefix) else { return nil }
        self.init(interface: interface, address: address, netmask: prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix))
    }

    /// The other address of a two-address link: a /30's other host, or a /31's other address. nil on anything bigger.
    public var peer: UInt32? {
        switch netmask {
        case 0xFFFF_FFFC:
            let network = address & netmask
            guard address == network + 1 || address == network + 2 else { return nil }
            return address == network + 1 ? network + 2 : network + 1
        case 0xFFFF_FFFE:
            return address ^ 1
        default:
            return nil
        }
    }

    /// 169.254.0.0/16: an address the device gave itself, having been given none.
    public var isSelfAssigned: Bool { address & 0xFFFF_0000 == 0xA9FE_0000 }

    /// This device as an iPhone sharing its connection (Personal Hotspot): 172.20.10.1/28, the network iOS always
    /// gives its hotspot. A Blackmagic camera with a phone on its USB-C is one of the hotspot's clients there (the
    /// PYXIS manual has the phone's Personal Hotspot on for it), so its address isn't the other half of a pair.
    public var isPersonalHotspot: Bool { address == 0xAC14_0A01 && netmask == 0xFFFF_FFF0 }

    public static func dotted(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String(value >> UInt32($0) & 0xFF) }.joined(separator: ".")
    }

    public static func value(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? 256) < 256 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1! }
    }
}

extension LocalAddresses {
    /// This device's IPv4 addresses (getifaddrs), each with its interface and netmask; loopback excluded.
    public static func ipv4ByInterface() -> [LocalIPv4] {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [LocalIPv4] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let mask = entry.pointee.ifa_netmask,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let value = { (p: UnsafeMutablePointer<sockaddr>) in
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            found.append(LocalIPv4(interface: String(cString: entry.pointee.ifa_name), address: value(sa), netmask: value(mask)))
        }
        return found
        #else
        return []
        #endif
    }
}

// MARK: - Listing them (Mac)

#if os(macOS)
import IOKit

/// A Blackmagic camera on this Mac's USB, as the IORegistry lists it: a Blackmagic device with a network interface
/// under it. A Speed Editor, or a capture device, has none.
public struct BlackmagicUSBCamera: Sendable, Equatable, Identifiable {
    /// Its USB serial number, normalized (`BlackmagicUSBSerial`).
    public var serial: String
    /// Its USB product name, e.g. "PYXIS 12K".
    public var product: String
    /// The network interface its cable makes, e.g. "en14".
    public var interface: String
    public var id: String { serial }
    public var host: String { USBCameraAddress.host(serial: serial) }

    public init(serial: String, product: String, interface: String) {
        self.serial = BlackmagicUSBSerial.normalised(serial)
        self.product = product
        self.interface = interface
    }

    /// Blackmagic Design's USB vendor ID.
    public static let vendorID = 0x1EDB

    /// Every Blackmagic camera on USB now. Reads the IORegistry only: nothing is opened.
    public static func connected() -> [BlackmagicUSBCamera] {
        devices().compactMap { device in
            device.interface.map { BlackmagicUSBCamera(serial: device.serial, product: device.product, interface: $0) }
        }
        .sorted { $0.product == $1.product ? $0.serial < $1.serial : $0.product < $1.product }
    }

    /// Every Blackmagic device on USB with a serial number, and the network interface under it: nil for one without
    /// any, or a camera whose interface macOS is still setting up.
    static func devices() -> [(serial: String, product: String, interface: String?)] {
        USBRegistry.entries("IOUSBHostDevice", where: ["idVendor": vendorID]) { service -> (serial: String, product: String, interface: String?)? in
            guard let serial = USBRegistry.string("USB Serial Number", of: service), !serial.isEmpty else { return nil }
            return (BlackmagicUSBSerial.normalised(serial), USBRegistry.string("USB Product Name", of: service) ?? "Blackmagic camera",
                    USBRegistry.string("BSD Name", below: service))
        }
    }
}
#endif
