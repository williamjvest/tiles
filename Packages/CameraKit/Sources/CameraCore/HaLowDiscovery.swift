import Foundation
import Network
import os
#if canImport(Darwin)
import Darwin
#endif

// What this device can learn about the network it's on, locally or from Bonjour, for HaLowMonitor to find nodes with.

// MARK: - Bonjour

/// Hosts that advertise a web server on the local network. Every OpenWrt node running avahi advertises its web
/// interface as `_http._tcp`; so do printers and NAS boxes, which is why HaLowMonitor checks each one.
public protocol HaLowNodeBrowser: Sendable {
    /// Browses for `seconds`, then stops, and returns what it found resolved to IPv4, each with its service name.
    func browse(seconds: Double) async -> [(address: String, name: String)]
}

/// `_http._tcp` over Bonjour (NWBrowser). One short browse, not a standing one: every query crosses a HaLow mesh
/// as multicast, at its slowest rate. Resolving a service means connecting to it (port 80), then canceling; that's
/// how Network.framework hands out a service's address. IPv4 only, since the nodes are polled by IPv4 address. A
/// service seen on several interfaces is tried on each: unpinned, a connection can stall on one that has no route
/// (a bridge member, on a Mac sharing its internet with a node).
public struct BonjourNodeBrowser: HaLowNodeBrowser {
    public init() {}

    public func browse(seconds: Double) async -> [(address: String, name: String)] {
        let services = await Self.services(seconds: seconds)
        return await withTaskGroup(of: (String, String)?.self) { group in
            for (endpoint, name, interfaces) in services {
                group.addTask { await Self.ipv4(of: endpoint, on: interfaces).map { ($0, name) } }
            }
            var hits: [(address: String, name: String)] = []
            for await hit in group {
                if let hit, !hits.contains(where: { $0.address == hit.0 }) { hits.append((hit.0, hit.1)) }
            }
            return hits
        }
    }

    private static func services(seconds: Double) async -> [(NWEndpoint, String, [NWInterface])] {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: .tcp)
        let queue = DispatchQueue(label: "halow.bonjour")
        let found = OSAllocatedUnfairLock(initialState: [(NWEndpoint, String, [NWInterface])]())
        browser.browseResultsChangedHandler = { results, _ in
            let services = results.compactMap { result -> (NWEndpoint, String, [NWInterface])? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return (result.endpoint, name, result.interfaces)
            }
            found.withLock { $0 = services }
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        return found.withLock { $0 }
    }

    /// The first of the service's interfaces to connect gives the address; the rest are canceled.
    private static func ipv4(of endpoint: NWEndpoint, on interfaces: [NWInterface]) async -> String? {
        let connections = (interfaces.isEmpty ? [nil] : interfaces.map(Optional.some)).map { interface in
            let parameters = NWParameters.tcp
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
            if let interface { parameters.requiredInterface = interface }
            return NWConnection(to: endpoint, using: parameters)
        }
        let queue = DispatchQueue(label: "halow.resolve")
        return await withCheckedContinuation { continuation in
            let state = OSAllocatedUnfairLock(initialState: (done: false, failed: 0))
            let finish: @Sendable (String?) -> Void = { address in
                let first = state.withLock { s -> Bool in
                    if address == nil { s.failed += 1; if s.failed < connections.count { return false } }
                    let first = !s.done
                    s.done = true
                    return first
                }
                guard first else { return }
                connections.forEach { $0.cancel() }
                continuation.resume(returning: address)
            }
            for connection in connections {
                connection.stateUpdateHandler = { update in
                    switch update {
                    case .ready:
                        if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint, case .ipv4(let ip) = host {
                            finish(ip.rawValue.map(String.init).joined(separator: "."))
                        } else {
                            finish(nil)
                        }
                    case .failed: finish(nil)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            queue.asyncAfter(deadline: .now() + 3) {
                guard state.withLock({ let first = !$0.done; $0.done = true; return first }) else { return }
                connections.forEach { $0.cancel() }
                continuation.resume(returning: nil)
            }
        }
    }
}

// MARK: - This device

/// This device's own IPv4 addresses (getifaddrs), loopback excluded. A node whose DHCP leases include one of them
/// gave this device its address.
public enum LocalAddresses {
    public static func ipv4() -> Set<String> {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            addresses.insert(withUnsafeBytes(of: ip) { $0.map(String.init).joined(separator: ".") })
        }
        return addresses
        #else
        return []
        #endif
    }
}

/// This network's IPv4 default gateway, read from the routing table (sysctl NET_RT_FLAGS). Local, no traffic. Nil if
/// the table can't be read. On a mesh whose nodes hand out a router, it's a node.
public enum DefaultGateway {
    public static func ipv4() -> String? {
        #if canImport(Darwin)
        // CTL_NET, PF_ROUTE, protocol 0, AF_INET, NET_RT_FLAGS (2), RTF_GATEWAY (0x2). The NET_RT_* constants are
        // missing from the iOS SDK headers, so they're spelled out.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, 2, 0x2]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(length)))
        #else
        return nil
        #endif
    }

    /// Walks the routing messages: a 92-byte rt_msghdr (layout identical on macOS and iOS; little-endian), then a
    /// sockaddr for each bit set in rtm_addrs (RTA_DST 0x1, RTA_GATEWAY 0x2, …), each padded to 4 bytes, sa_len 0
    /// meaning all zeros. Returns the gateway of the 0.0.0.0 route.
    static func parse(_ bytes: [UInt8]) -> String? {
        let headerSize = 92
        var offset = 0
        while offset + headerSize <= bytes.count {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard length >= headerSize, offset + length <= bytes.count else { return nil }
            let addrs = Int(bytes[offset + 12]) | Int(bytes[offset + 13]) << 8
            var cursor = offset + headerSize
            var destination: [UInt8]?
            var gateway: [UInt8]?
            for bit in 0..<8 where addrs & (1 << bit) != 0 && cursor < offset + length {
                let saLen = Int(bytes[cursor])
                if saLen == 0 {
                    if bit == 0 { destination = [0, 0, 0, 0] }
                } else if saLen >= 8, bytes[cursor + 1] == 2 /* AF_INET */, cursor + 8 <= offset + length {
                    let ip = Array(bytes[(cursor + 4)..<(cursor + 8)])
                    if bit == 0 { destination = ip } else if bit == 1 { gateway = ip }
                }
                cursor += saLen == 0 ? 4 : (saLen + 3) & ~3
            }
            if destination == [0, 0, 0, 0], let gateway, gateway != [0, 0, 0, 0] {
                return gateway.map(String.init).joined(separator: ".")
            }
            offset += length
        }
        return nil
    }
}
