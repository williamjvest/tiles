import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A Sony camera on one of this device's networks, as its UPnP description has it (`DigitalImagingDesc.xml`). Add
/// Camera lists these so a camera's address can be picked rather than typed.
public struct SonyNetworkCamera: Sendable, Hashable, Identifiable {
    public var id: String { host }
    /// Its IPv4 address.
    public var host: String
    /// `X_ModelName`: "ILME-FX5", "MPC-2610".
    public var model: String
    /// `X_FirmwareVersion`.
    public var firmware: String?
    /// `X_SSH_Support` Enable: Access Authentication is on, so the camera takes Camera Remote only over SSH, with the user
    /// name and password set on it (docs/protocol.md §2.2).
    public var needsLogin: Bool

    public init(host: String, model: String, firmware: String? = nil, needsLogin: Bool = false) {
        self.host = host
        self.model = model
        self.firmware = firmware
        self.needsLogin = needsLogin
    }

    /// From a `DigitalImagingDesc.xml`; nil if it names no model.
    public init?(host: String, description xml: String) {
        guard let model = Self.value("X_ModelName", in: xml), !model.isEmpty else { return nil }
        self.init(host: host, model: model, firmware: Self.value("X_FirmwareVersion", in: xml),
                  needsLogin: Self.value("X_SSH_Support", in: xml)?.caseInsensitiveCompare("Enable") == .orderedSame)
    }

    /// What Tiles calls it: "FX5", "BURANO".
    public var name: String { CameraState.modelName(model) }

    /// One element's text in Sony's description, which names each of its elements once.
    static func value(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound ..< xml.endIndex) else { return nil }
        return String(xml[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Finds the Sony cameras on this device's networks that have Camera Remote Control on, two ways at once:
/// - SSDP, as Sony documents it: an M-SEARCH for `urn:schemas-sony-com:service:DigitalImaging:1`, answered with where
///   the camera's description is (e.g. `http://192.0.2.254:64321/dd.xml`).
/// - Every other address of this device's own networks asked for that description on 64321, where the FX5, the FX6 and
///   the BURANO all serve it. iOS sends no multicast without an entitlement Apple grants, so on an iPhone or iPad this
///   is what finds them; the FX5 doesn't answer an M-SEARCH sent to its own address either.
public enum SonyDiscovery {
    /// Where a Sony camera serves its description: the FX5's, the FX6's and the BURANO's port.
    public static let descriptionPort: UInt16 = 64321
    static let searchTarget = "urn:schemas-sony-com:service:DigitalImaging:1"

    /// Each camera as it's found, then the end: about `seconds`, a few more on a network with many silent addresses.
    public static func search(seconds: Double = 3) -> AsyncStream<SonyNetworkCamera> {
        search(hosts: hosts(on: LocalAddresses.ipv4ByInterface()), port: descriptionPort, multicast: true, seconds: seconds)
    }

    /// These addresses asked, not every address of the networks, and SSDP: on a HaLow mesh, the devices its nodes leased
    /// an address to. A sweep of a /24 sends about 240 broadcast ARP requests, which every node of a mesh
    /// carries over a link that moves 64 kbit/s on a bad day.
    public static func search(hosts: [String], seconds: Double = 3) -> AsyncStream<SonyNetworkCamera> {
        search(hosts: hosts, port: descriptionPort, multicast: true, seconds: seconds)
    }

    /// `hosts` asked on `port`, and SSDP if `multicast`.
    static func search(hosts: [String], port: UInt16, multicast: Bool, seconds: Double) -> AsyncStream<SonyNetworkCamera> {
        AsyncStream { continuation in
            let task = Task {
                let seen = Seen()
                // Its own session for what SSDP points at, so it isn't queued behind the sweep's asks; and a longer
                // wait for the addresses asked again.
                let session = probeSession(seconds: min(1.5, seconds)), described = probeSession(seconds: 3),
                    patient = probeSession(seconds: 3)
                defer {
                    session.invalidateAndCancel()
                    described.invalidateAndCancel()
                    patient.invalidateAndCancel()
                }
                let found: @Sendable (SonyNetworkCamera?) -> Void = { camera in
                    if let camera, seen.first(camera.host) { continuation.yield(camera) }
                }
                await withTaskGroup(of: Void.self) { group in
                    if multicast {
                        group.addTask {
                            await withTaskGroup(of: Void.self) { group in
                                for await location in ssdpLocations(seconds: seconds) {
                                    group.addTask { found(await describe(location, session: described)) }
                                }
                            }
                        }
                    }
                    group.addTask {
                        // Every address, then again those that gave no answer at all: a camera whose Wi-Fi was asleep
                        // can take longer than the first wait to answer its first packet, and was found only on a
                        // second search (an FX5). By then an address no one has fails at once.
                        let silent = await sweep(hosts, port: port, session: session, found: found)
                        if !silent.isEmpty, !Task.isCancelled {
                            _ = await sweep(silent, port: port, session: patient, found: found)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The addresses to ask on each network: every host of it but this device (on any of its interfaces: a Mac on one
    /// network twice, Wi-Fi and Ethernet), and no more than the /24 this device is in (a /16 is 65,000 addresses). Not a
    /// link with no one else on it (/32: cellular, a VPN's tunnel), nor an address the device gave itself, nor a tunnel
    /// or Apple's peer-to-peer link.
    static func hosts(on networks: [LocalIPv4]) -> [String] {
        let mine = Set(networks.map(\.address))
        var hosts: [UInt32] = []
        for network in networks where !network.isSelfAssigned
            && !["utun", "ipsec", "pdp_ip", "awdl", "llw"].contains(where: network.interface.hasPrefix) {
            let mask = max(network.netmask, 0xFFFF_FF00)
            guard mask != 0xFFFF_FFFF else { continue }
            if mask == 0xFFFF_FFFE {
                if let peer = network.peer { hosts.append(peer) }
                continue
            }
            let base = network.address & mask, broadcast = base | ~mask
            hosts += base + 1 ..< broadcast
        }
        var seen = mine
        return hosts.filter { seen.insert($0).inserted }.map(LocalIPv4.dotted)
    }

    /// Asks each of `hosts`, a few at a time, telling each camera found as it's found; returns the hosts that didn't
    /// answer at all before the wait ran out.
    static func sweep(_ hosts: [String], port: UInt16, session: URLSession,
                      found: @escaping @Sendable (SonyNetworkCamera?) -> Void) async -> [String] {
        // At most this many asks at once: each holds a socket until it's answered or gives up, and an address no one
        // has is given up on only at the timeout the first time (1.5 s, for a camera across a HaLow mesh), so a first
        // sweep of a /24 takes about 6 s. Found ones show at once.
        let width = 64
        var silent: [String] = []
        await withTaskGroup(of: (String, Probe).self) { asks in
            var next = hosts.makeIterator()
            for _ in 0 ..< width {
                guard let host = next.next() else { break }
                asks.addTask { (host, await probe(host, port: port, session: session)) }
            }
            while let (host, answer) = await asks.next() {
                switch answer {
                case .camera(let camera): found(camera)
                case .silent: silent.append(host)
                case .nothing: break
                }
                if let host = next.next(), !Task.isCancelled {
                    asks.addTask { (host, await probe(host, port: port, session: session)) }
                }
            }
        }
        return silent
    }

    enum Probe: Sendable {
        case camera(SonyNetworkCamera)
        /// No answer before the wait ran out.
        case silent
        /// An answer that isn't a Sony camera's description, or a refusal.
        case nothing
    }

    /// `host`'s description on `port`, if it's a Sony camera's.
    static func probe(_ host: String, port: UInt16, session: URLSession) async -> Probe {
        guard let url = URL(string: "http://\(host):\(port)/DigitalImagingDesc.xml") else { return .nothing }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let camera = SonyNetworkCamera(host: host, description: String(decoding: data, as: UTF8.self)) else {
                return .nothing
            }
            return .camera(camera)
        } catch let error as URLError where error.code == .timedOut {
            return .silent
        } catch {
            return .nothing
        }
    }

    /// The camera an SSDP answer points at: its `dd.xml`, then the description that names (`SCPDURL`), else the
    /// description at the usual path.
    static func describe(_ location: URL, session: URLSession) async -> SonyNetworkCamera? {
        guard let host = location.host else { return nil }
        let path = await text(at: location, session: session).flatMap { SonyNetworkCamera.value("SCPDURL", in: $0) }
        guard let url = URL(string: path ?? "/DigitalImagingDesc.xml", relativeTo: location),
              let xml = await text(at: url, session: session) else { return nil }
        return SonyNetworkCamera(host: host, description: xml)
    }

    private static func text(at url: URL, session: URLSession) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Short waits: a silent address is given up on, not waited out (most addresses on a network are no one's).
    private static func probeSession(seconds: Double) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds
        config.timeoutIntervalForResource = seconds + 1
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }

    // MARK: - SSDP

    static var searchRequest: String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(searchTarget)\r\n"
            + "USER-AGENT: Tiles\r\n\r\n"
    }

    /// The description's address in an answer to the search, if it's an answer from a Sony camera.
    static func location(inAnswer answer: String) -> URL? {
        var location: URL?
        var sony = false
        for line in answer.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "LOCATION" { location = URL(string: value) }
            if name == "ST" || name == "USN" || name == "NT" { sony = sony || value.contains(searchTarget) }
        }
        return sony ? location : nil
    }

    /// The search, sent three times over the first second (it's UDP), and each description address answered within
    /// `seconds`. Nothing where this device can't send multicast.
    static func ssdpLocations(seconds: Double) -> AsyncStream<URL> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.finish() }
                #if canImport(Darwin)
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var ttl: UInt8 = 2
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
                var wait = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                var group = sockaddr_in()
                group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                group.sin_family = sa_family_t(AF_INET)
                group.sin_port = UInt16(1900).bigEndian
                group.sin_addr.s_addr = inet_addr("239.255.255.250")
                let request = Array(searchRequest.utf8)
                func send() -> Bool {
                    withUnsafePointer(to: &group) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == request.count
                        }
                    }
                }
                guard send() else { return }
                let start = Date()
                var sent = 1
                var told = Set<URL>()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while Date().timeIntervalSince(start) < seconds {
                    let elapsed = Date().timeIntervalSince(start)
                    if (sent == 1 && elapsed > 0.3) || (sent == 2 && elapsed > 0.8) {
                        _ = send()
                        sent += 1
                    }
                    let count = recv(fd, &buffer, buffer.count, 0)
                    guard count > 0 else { continue }
                    if let location = location(inAnswer: String(decoding: buffer[0 ..< count], as: UTF8.self)),
                       told.insert(location).inserted {
                        continuation.yield(location)
                    }
                }
                #endif
            }
        }
    }

    /// Hosts already told of, from both searches at once.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts = Set<String>()
        func first(_ host: String) -> Bool { lock.withLock { hosts.insert(host).inserted } }
    }
}
