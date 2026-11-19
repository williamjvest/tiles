import Foundation

// MARK: - Devices on the HaLow mesh

/// A device on the mesh, as its nodes know it: a DHCP lease from a node's dnsmasq, or a static lease (OpenWrt's
/// `dhcp` `host` sections). Add Camera lists these so a camera's address can be picked rather than typed.
public struct MeshDevice: Sendable, Equatable, Identifiable {
    public var id: String { "\(ip) \(mac)" }
    /// IPv4 address, e.g. "192.0.2.21".
    public var ip: String
    /// Lower-case MAC. For a static lease nobody holds right now, the first of its MACs.
    public var mac: String
    /// The name in the lease: what the device called itself, or its static lease's name, which dnsmasq puts in its
    /// place.
    public var hostname: String?
    /// The name its static lease gives it.
    public var staticName: String?
    /// The node that leased it the address (its hostname when known). nil: a static lease with no current lease.
    public var node: String?
    /// When the lease runs out; nil for a lease that doesn't expire or a static lease with no lease.
    public var leaseExpires: Date?

    public init(ip: String, mac: String, hostname: String? = nil, staticName: String? = nil, node: String? = nil,
                leaseExpires: Date? = nil) {
        self.ip = ip
        self.mac = mac
        self.hostname = hostname
        self.staticName = staticName
        self.node = node
        self.leaseExpires = leaseExpires
    }

    /// What to call it: its static lease's name, else what it called itself.
    public var name: String? { staticName ?? hostname }
    /// On the mesh now: some node has leased it an address.
    public var isPresent: Bool { node != nil }
    /// Who made it, when it's a camera that says so (`MeshDeviceList.cameraMaker`).
    public var cameraMaker: ProfileCameraType? { MeshDeviceList.cameraMaker(hostname: hostname, mac: mac) }
}

/// What a scan of the nodes found, and why any node couldn't be read.
public struct MeshDeviceScan: Sendable, Equatable {
    public var devices: [MeshDevice]
    /// Node address → what went wrong, in words.
    public var problems: [String: String]

    public init(devices: [MeshDevice] = [], problems: [String: String] = [:]) {
        self.devices = devices
        self.problems = problems
    }
}

/// Reading and merging what the nodes report.
public enum MeshDeviceList {
    /// A `dhcp` `host` section: OpenWrt's static lease. `mac` may hold several (one device, several interfaces).
    public struct StaticLease: Sendable, Equatable {
        public var name: String?
        public var macs: [String]
        public var ip: String
    }

    /// Leases from `luci-rpc getDHCPLeases`: `expires` is seconds remaining (Int), or `false` / ≤0 for none. MACs
    /// arrive upper-case from LuCI and are lower-cased; `hostname` is optional.
    public static func leases(_ items: [[String: Any]], node: String, now: Date) -> [MeshDevice] {
        items.compactMap { item in
            guard let ip = item["ipaddr"] as? String, isIPv4(ip), let mac = item["macaddr"] as? String else { return nil }
            var leaseExpires: Date?
            if let seconds = item["expires"] as? Int, seconds > 0 { leaseExpires = now.addingTimeInterval(TimeInterval(seconds)) }
            let hostname = (item["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return MeshDevice(ip: ip, mac: mac.lowercased(), hostname: hostname, node: node, leaseExpires: leaseExpires)
        }
    }

    /// Static leases from `uci get {config: dhcp, type: host}`'s `values`: sections with an IPv4 `ip`. `mac` is a
    /// space-separated string or a list, as uci keeps either.
    public static func staticLeases(_ values: [String: Any]) -> [StaticLease] {
        values.values.compactMap { value in
            guard let section = value as? [String: Any], section[".type"] as? String == "host",
                  let ip = section["ip"] as? String, isIPv4(ip) else { return nil }
            let macs = ((section["mac"] as? [String]) ?? (section["mac"] as? String).map { $0.split(separator: " ").map(String.init) } ?? [])
                .map { $0.lowercased() }
            let name = (section["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return StaticLease(name: name, macs: macs, ip: ip)
        }
        .sorted { ipKey($0.ip).lexicographicallyPrecedes(ipKey($1.ip)) }
    }

    /// One list from every node's leases and static leases. A device several nodes have leased to (it moved) keeps its
    /// newest lease. A lease on a static lease's address, or from one of its MACs, takes its name. A static lease nobody
    /// holds is listed too, as not present. Cameras first, then by address.
    public static func merge(leases: [MeshDevice], staticLeases: [StaticLease]) -> [MeshDevice] {
        var byMAC: [String: MeshDevice] = [:]
        for lease in leases {
            if let kept = byMAC[lease.mac], expires(kept) >= expires(lease) { continue }
            byMAC[lease.mac] = lease
        }
        var devices = Array(byMAC.values)
        for index in devices.indices {
            devices[index].staticName = staticLeases.first {
                $0.ip == devices[index].ip || $0.macs.contains(devices[index].mac)
            }?.name
        }
        for row in staticLeases where !devices.contains(where: { $0.ip == row.ip || row.macs.contains($0.mac) }) {
            devices.append(MeshDevice(ip: row.ip, mac: row.macs.first ?? "", staticName: row.name))
        }
        return devices.sorted { a, b in
            if (a.cameraMaker != nil) != (b.cameraMaker != nil) { return a.cameraMaker != nil }
            return ipKey(a.ip).lexicographicallyPrecedes(ipKey(b.ip))
        }
    }

    /// A camera, by what it says about itself: Sony's cameras send `SonyImagingDevice` as their DHCP hostname (their
    /// Wi-Fi modules carry the module maker's OUI, e.g. Murata's, so the MAC can't tell); otherwise the maker's IEEE
    /// OUI on its network port: Blackmagic Design 7C:2E:0D, Sony Imaging Products & Solutions 2C:97:ED. A static
    /// lease's name replaces the hostname in the lease, so a camera with one is known by that name instead. ARRI
    /// (Arnold & Richter Cine Technik) is 84:90:00 in the IEEE register.
    public static func cameraMaker(hostname: String?, mac: String) -> ProfileCameraType? {
        if hostname?.caseInsensitiveCompare("SonyImagingDevice") == .orderedSame { return .sony }
        switch mac.lowercased().prefix(8) {
        case "7c:2e:0d": return .blackmagic
        case "2c:97:ed": return .sony
        case "84:90:00": return .arri
        default: return nil
        }
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func expires(_ device: MeshDevice) -> Date { device.leaseExpires ?? .distantFuture }

    private static func ipKey(_ ip: String) -> [Int] { ip.split(separator: ".").map { Int($0) ?? 0 } }
}
