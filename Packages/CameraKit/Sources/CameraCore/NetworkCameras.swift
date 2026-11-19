import Foundation

/// A camera on one of this device's networks, from any maker Tiles can find there: Add Camera's list of them, so a
/// camera's address can be picked rather than typed.
public struct NetworkCamera: Sendable, Hashable, Identifiable {
    public var id: String { host }
    /// Its IPv4 address.
    public var host: String
    public var maker: ProfileCameraType
    /// What Tiles calls it: "FX5", "PYXIS 12K".
    public var name: String
    /// The model as the camera gives it, where that isn't its name: "ILME-FX5".
    public var model: String?
    /// A Sony with Access Authentication on: it takes Camera Remote only with the user name and password set on it.
    public var needsLogin: Bool

    public init(host: String, maker: ProfileCameraType, name: String, model: String? = nil, needsLogin: Bool = false) {
        self.host = host
        self.maker = maker
        self.name = name
        self.model = model
        self.needsLogin = needsLogin
    }

    public init(_ sony: SonyNetworkCamera) {
        self.init(host: sony.host, maker: .sony, name: sony.name, model: sony.model == sony.name ? nil : sony.model,
                  needsLogin: sony.needsLogin)
    }
}

/// Finds the cameras on this device's networks, every maker at once, each as it's found: Sony cameras with Camera
/// Remote Control on (`SonyDiscovery`: SSDP, and each address asked for its description), and Blackmagic cameras
/// advertising over Bonjour on a network rather than a cable (`BlackmagicAdverts`; those on a cable are Add Camera's
/// USB list). ARRI and VENICE cameras announce nothing Tiles can find, so their addresses are typed in.
public enum NetworkCameras {
    /// Each camera as it's found, then the end: about `seconds`, a few more for a first sweep of a network. `hosts`: the
    /// addresses to ask for a Sony camera's description instead of every address of this device's networks (on a HaLow
    /// mesh, the devices its nodes leased one to; `SonyDiscovery.search(hosts:)`).
    public static func search(seconds: Double = 3, hosts: [String]? = nil) -> AsyncStream<NetworkCamera> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let sonies = hosts.map { SonyDiscovery.search(hosts: $0, seconds: seconds) }
                            ?? SonyDiscovery.search(seconds: seconds)
                        for await sony in sonies { continuation.yield(NetworkCamera(sony)) }
                    }
                    group.addTask {
                        // Browsed for the whole app once started; each advert's address asked as it comes.
                        let adverts = BlackmagicAdverts.shared
                        adverts.start()
                        var told = Set<String>()
                        let end = ContinuousClock.now + .seconds(seconds)
                        while ContinuousClock.now < end, !Task.isCancelled {
                            adverts.resolveEveryAdvert()
                            for camera in blackmagic(adverts.adverts, resolved: adverts.resolved,
                                                     among: LocalAddresses.ipv4ByInterface())
                            where told.insert(camera.host).inserted {
                                continuation.yield(camera)
                            }
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The Blackmagic cameras among `adverts` on a network, not a cable, each once, at the address its advert was asked
    /// for (`resolved`, by `BlackmagicAdverts.key`); one not asked yet waits for the next look.
    static func blackmagic(_ adverts: [BlackmagicAdverts.Advert], resolved: [String: String],
                           among addresses: [LocalIPv4]) -> [NetworkCamera] {
        let cabled = Set(BlackmagicAdverts.onCables(adverts, among: addresses).map(\.serial))
        var seen = Set<String>()
        return adverts.compactMap { advert in
            guard !cabled.contains(advert.serial), advert.link != .cellular,
                  let host = resolved[BlackmagicAdverts.key(advert)], seen.insert(advert.serial).inserted else { return nil }
            return NetworkCamera(host: host, maker: .blackmagic, name: advert.product)
        }
    }
}
