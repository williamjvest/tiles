import Foundation
import Network

/// Blackmagic cameras advertising themselves over Bonjour on any of this device's interfaces: `_http._tcp` with TXT
/// `capabilities` including `cameraControl`, and the camera's `unique id`. One browse for the whole app, started on
/// first use. On iPhone and iPad it's how a camera on a USB-C cable is found: its advert comes over the cable's
/// interface, and its unique id is the serial its USB device has on a Mac, so either finds the same saved camera.
public final class BlackmagicAdverts: @unchecked Sendable {
    public static let shared = BlackmagicAdverts()

    /// The kind of interface an advert came on, as Network.framework says.
    public enum Link: String, Sendable, Hashable {
        case wired, wifi = "Wi-Fi", cellular, other
    }

    /// One camera's advert, on one interface.
    public struct Advert: Sendable, Equatable, Hashable {
        /// Its `unique id`, normalized (`BlackmagicUSBSerial`).
        public var serial: String
        /// Its `product name`, e.g. "PYXIS 12K".
        public var product: String
        /// The interface it came on, e.g. "en2".
        public var interface: String
        public var link: Link
        public var isWired: Bool { link == .wired }
        /// Could be a cable's link: wired, or a kind the system doesn't name (a USB network it sets up itself). Whether it
        /// is, is the addresses' to say (`BlackmagicUSBLink.isCable`).
        public var mayBeCable: Bool { link == .wired || link == .other }
        public var host: String { USBCameraAddress.host(serial: serial) }

        public init(serial: String, product: String, interface: String, link: Link) {
            self.serial = BlackmagicUSBSerial.normalised(serial)
            self.product = product
            self.interface = interface
            self.link = link
        }

        public init(serial: String, product: String, interface: String, isWired: Bool) {
            self.init(serial: serial, product: product, interface: interface, link: isWired ? .wired : .wifi)
        }

        /// From a TXT record: nil unless it's a camera Tiles can control, with its unique id.
        public init?(txt: [String: String], interface: String, link: Link) {
            guard let serial = txt["unique id"], !serial.isEmpty,
                  txt["capabilities"]?.split(whereSeparator: { $0 == "," || $0 == " " }).contains("cameraControl") == true
            else { return nil }
            let product = [txt["product name"], txt["device name"]].compactMap { $0 }.first { !$0.isEmpty }
            self.init(serial: serial, product: product ?? "Blackmagic camera", interface: interface, link: link)
        }

        public init?(txt: [String: String], interface: String, isWired: Bool) {
            self.init(txt: txt, interface: interface, link: isWired ? .wired : .wifi)
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "BlackmagicAdverts")
    private var browser: NWBrowser?
    private var browsing = "not started"
    private var startedAt: ContinuousClock.Instant?
    private var current: [Advert] = []
    private var watchers: [UUID: @Sendable (Advert) -> Void] = [:]
    /// Each advert's service and interface, by `key`, for asking its address.
    private var services: [String: (endpoint: NWEndpoint, interface: NWInterface)] = [:]
    private var addresses: [String: String] = [:]
    private var asking: [String: NWConnection] = [:]
    private var lastAsked: [String: ContinuousClock.Instant] = [:]
    private var everyAdvert = false
    /// Ask every advert's address, not only those on a Personal Hotspot: `camctl usb bonjour --resolve`, to check the
    /// asking on a Mac.
    public var resolvesEveryAdvert: Bool {
        get { lock.withLock { everyAdvert } }
        set { lock.withLock { everyAdvert = newValue } }
    }

    /// What's advertised now.
    public var adverts: [Advert] { lock.withLock { current } }

    /// The addresses asked of adverts (`resolveHotspotAdverts`), by `key`.
    public var resolved: [String: String] { lock.withLock { addresses } }

    /// An advert's key: its camera and interface.
    public static func key(_ advert: Advert) -> String { "\(advert.serial)|\(advert.interface)" }

    /// On this iPhone's Personal Hotspot: the camera is one of its clients, at an address its advert has to be asked
    /// for. Whatever kind of interface the system calls the hotspot's, except cellular.
    public static func onHotspot(_ advert: Advert, among addresses: [LocalIPv4]) -> Bool {
        advert.link != .cellular && addresses.contains { $0.interface == advert.interface && $0.isPersonalHotspot }
    }

    /// How long it's been browsing: zero before it starts.
    public var lookingFor: Duration { lock.withLock { startedAt.map { ContinuousClock.now - $0 } ?? .zero } }

    /// The cameras on a cable here now (`onCables(_:among:)`).
    public func onCables(among addresses: [LocalIPv4] = LocalAddresses.ipv4ByInterface()) -> [Advert] {
        Self.onCables(adverts, among: addresses)
    }

    /// The cameras of `adverts` on a cable, one each: an advert on an interface that may be a cable's (`mayBeCable`)
    /// and is a two-address link, or on this iPhone's Personal Hotspot (`onHotspot`).
    public static func onCables(_ adverts: [Advert], among addresses: [LocalIPv4]) -> [Advert] {
        var seen = Set<String>()
        return adverts.filter {
            ($0.mayBeCable && BlackmagicUSBLink.isCable($0.interface, among: addresses)) || onHotspot($0, among: addresses)
        }
            .sorted { $0.product == $1.product ? $0.serial < $1.serial : $0.product < $1.product }
            .filter { seen.insert($0.serial).inserted }
    }

    /// Starts browsing, if it isn't. It stops if the browse fails (say Tiles isn't allowed on the local network); the
    /// next call starts it again.
    public func start() {
        lock.withLock {
            guard browser == nil else { return }
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_http._tcp", domain: "local."), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
            browser.stateUpdateHandler = { [weak self] state in
                self?.lock.withLock { self?.browsing = "\(state)" }
                if case .failed = state { self?.stopped(browser) }
            }
            self.browser = browser
            startedAt = .now
            browser.start(queue: queue)
        }
    }

    /// `appeared` for each advert from now on that wasn't there before. Kept until `stopWatching`.
    public func watch(_ appeared: @escaping @Sendable (Advert) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { watchers[token] = appeared }
        return token
    }

    public func stopWatching(_ token: UUID) {
        _ = lock.withLock { watchers.removeValue(forKey: token) }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var services: [String: (endpoint: NWEndpoint, interface: NWInterface)] = [:]
        let found = results.flatMap { result -> [Advert] in
            guard case .bonjour(let record) = result.metadata else { return [] }
            let txt = record.dictionary
            return result.interfaces.compactMap { interface in
                guard let advert = Advert(txt: txt, interface: interface.name, link: Self.link(interface.type)) else { return nil }
                services[Self.key(advert)] = (result.endpoint, interface)
                return advert
            }
        }
        let (appeared, calls) = lock.withLock {
            let appeared = found.filter { !current.contains($0) }
            current = found
            self.services = services
            // An advert gone takes its address with it: back on the cable, the camera may have been given another.
            addresses = addresses.filter { services[$0.key] != nil }
            lastAsked = lastAsked.filter { services[$0.key] != nil }
            return (appeared, Array(watchers.values))
        }
        resolveHotspotAdverts()
        for advert in appeared { for call in calls { call(advert) } }
    }

    /// Asks the address of each advert on this iPhone's Personal Hotspot not asked yet (of every advert, with
    /// `resolvesEveryAdvert`): a UDP connection to its service over its interface, IPv4 only, is ready once the
    /// service is resolved, with no packet sent, so it answers whether or not anything listens on the advert's port (a
    /// PYXIS with only Remote Control on may not on 80). Again on a later look while one isn't answered, at most every
    /// 2 s for each advert: a failed ask isn't kept.
    public func resolveHotspotAdverts(among addresses: [LocalIPv4] = LocalAddresses.ipv4ByInterface()) {
        resolve(all: false, among: addresses)
    }

    /// Asks the address of every advert not asked yet, wherever it came from: for Add Camera's list of the cameras on
    /// the network (`NetworkCameras`).
    public func resolveEveryAdvert() {
        resolve(all: true, among: [])
    }

    private func resolve(all: Bool, among addresses: [LocalIPv4]) {
        let now = ContinuousClock.now
        let wanted: [(key: String, endpoint: NWEndpoint, interface: NWInterface)] = lock.withLock {
            current.compactMap { advert in
                let key = Self.key(advert)
                guard self.addresses[key] == nil, asking[key] == nil, let service = services[key],
                      lastAsked[key].map({ now - $0 >= .seconds(2) }) ?? true,
                      all || everyAdvert || Self.onHotspot(advert, among: addresses) else { return nil }
                return (key, service.endpoint, service.interface)
            }
        }
        for one in wanted { ask(one.key, one.endpoint, on: one.interface) }
    }

    private func ask(_ key: String, _ endpoint: NWEndpoint, on interface: NWInterface) {
        let parameters = NWParameters.udp
        parameters.requiredInterface = interface
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let claimed = lock.withLock { () -> Bool in
            guard asking[key] == nil else { return false }
            asking[key] = connection
            lastAsked[key] = .now
            return true
        }
        guard claimed else { return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let v4) = host {
                    let dotted = v4.rawValue.map { String($0) }.joined(separator: ".")
                    // Only the ask still current: not one from before the browse stopped, or one since replaced.
                    self.lock.withLock { if self.asking[key] === connection { self.addresses[key] = dotted } }
                }
                connection.cancel()
            case .waiting:
                connection.cancel()
            case .failed, .cancelled:
                self.lock.withLock { if self.asking[key] === connection { self.asking[key] = nil } }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Not answered in 5 s: given up, and asked again on a later look.
        queue.asyncAfter(deadline: .now() + 5) { [weak connection] in connection?.cancel() }
    }

    static func link(_ type: NWInterface.InterfaceType) -> Link {
        switch type {
        case .wiredEthernet: .wired
        case .wifi: .wifi
        case .cellular: .cellular
        default: .other
        }
    }

    /// What the browse has found and this device's addresses, for the Activity Log when a camera on a cable isn't found:
    /// which step a missing one fails at (no advert at all, an advert on a link that isn't a cable's, or no address).
    public func describe(among addresses: [LocalIPv4] = LocalAddresses.ipv4ByInterface()) -> String {
        let (state, found, asked) = lock.withLock { (browsing, current, self.addresses) }
        return Self.describe(browsing: state, adverts: found, addresses: addresses, resolved: asked)
    }

    static func describe(browsing: String, adverts: [Advert], addresses: [LocalIPv4],
                         resolved: [String: String] = [:]) -> String {
        let seen = adverts.isEmpty ? "no camera adverts"
            : "camera adverts: " + adverts.map { advert in
                "\(advert.product) …\(advert.serial.suffix(4)) on \(advert.interface) (\(advert.link.rawValue))"
                    + (resolved[key(advert)].map { " at \($0)" } ?? "")
            }.joined(separator: ", ")
        let mine = addresses.map { "\($0.interface) \(LocalIPv4.dotted($0.address))/\($0.netmask.nonzeroBitCount)" }
            .joined(separator: ", ")
        return "Bonjour browse \(browsing); \(seen); this device's IPv4: \(mine.isEmpty ? "none" : mine)"
    }

    private func stopped(_ failed: NWBrowser) {
        let asks: [NWConnection] = lock.withLock {
            guard browser === failed else { return [] }
            browser = nil
            startedAt = nil
            current = []
            services = [:]
            addresses = [:]
            lastAsked = [:]
            defer { asking = [:] }
            return Array(asking.values)
        }
        for ask in asks { ask.cancel() }
        failed.cancel()
    }
}
