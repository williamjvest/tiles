// Add Camera's list of the cameras on the network (`NetworkCameras`): the search for Sony cameras (`SonyDiscovery`),
// against what an FX5 served and answered (192.0.2.254, Camera Remote Control with Access Authentication on),
// and the Blackmagic cameras' adverts.

import Foundation
import Network
import Testing
@testable import CameraCore
import CameraKitTestSupport

@Suite("Cameras on the network")
struct SonyDiscoveryTests {
    /// An FX5's `DigitalImagingDesc.xml`, as it serves it on 64321 (its serial and MAC replaced).
    static let fx5Description = """
        <?xml version="1.0" encoding="utf-8"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major>\
        <minor>0</minor></specVersion><serviceStateTable><stateVariable sendEvents="no"><name>X_DigitalImagingDeviceInfo</name>\
        <dataType>string</dataType></stateVariable></serviceStateTable><X_DigitalImagingDeviceInfo><X_DeviceInfo>\
        <X_ModelName>ILME-FX5</X_ModelName><X_FirmwareVersion>1.00</X_FirmwareVersion><X_ServerType>Pro Camera Remote \
        Control</X_ServerType><X_ServerVersion>1.00</X_ServerVersion><X_SerialVersion>1000004</X_SerialVersion>\
        </X_DeviceInfo><X_PTP_Information><X_PTP_Versions>3.00</X_PTP_Versions></X_PTP_Information><X_ConnectionInfo>\
        <X_SSH_Support>Enable</X_SSH_Support><X_SSH_QRSetupSupport>Enable</X_SSH_QRSetupSupport></X_ConnectionInfo>\
        </X_DigitalImagingDeviceInfo></scpd>
        """

    /// Its `dd.xml`, which names the description's path.
    static let fx5DeviceDescription = """
        <?xml version="1.0" encoding="utf-8"?><root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major>\
        <minor>0</minor></specVersion><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>\
        <manufacturer>Sony Corporation</manufacturer><modelName>SonyImagingDevice</modelName>\
        <UDN>uuid:00000000-0005-0010-8000-000000000004</UDN><serviceList><service>\
        <serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType>\
        <serviceId>urn:schemas-sony-com:serviceId:DigitalImaging</serviceId><SCPDURL>/DigitalImagingDesc.xml</SCPDURL>\
        <controlURL>/upnp/control/DigitalImaging</controlURL><eventSubURL/></service></serviceList></device></root>
        """

    /// Its answer to the M-SEARCH.
    static let fx5Answer = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT: \r\n"
        + "LOCATION: http://192.0.2.254:64321/dd.xml\r\nSERVER: UPnP/1.0 SonyImagingDevice/1.0\r\n"
        + "ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n"
        + "USN: uuid:00000000-0005-0010-8000-000000000004::urn:schemas-sony-com:service:DigitalImaging:1\r\n\r\n"

    @Test("The description: the model, Tiles' name for it, the firmware, and whether it wants its login")
    func description() throws {
        let fx5 = try #require(SonyNetworkCamera(host: "192.0.2.254", description: Self.fx5Description))
        #expect(fx5 == SonyNetworkCamera(host: "192.0.2.254", model: "ILME-FX5", firmware: "1.00", needsLogin: true))
        #expect(fx5.name == "FX5")
        let open = Self.fx5Description.replacingOccurrences(of: "<X_SSH_Support>Enable", with: "<X_SSH_Support>Disable")
        #expect(SonyNetworkCamera(host: "h", description: open)?.needsLogin == false)
        let burano = Self.fx5Description.replacingOccurrences(of: "ILME-FX5", with: "MPC-2610")
        #expect(SonyNetworkCamera(host: "h", description: burano)?.name == "BURANO")
        #expect(SonyNetworkCamera(host: "h", description: "<html><body>Router</body></html>") == nil)
    }

    @Test("An answer to the search: where its description is, from a Sony camera only")
    func answer() {
        #expect(SonyDiscovery.location(inAnswer: Self.fx5Answer) == URL(string: "http://192.0.2.254:64321/dd.xml"))
        let printer = Self.fx5Answer.replacingOccurrences(of: "urn:schemas-sony-com:service:DigitalImaging:1",
                                                          with: "urn:schemas-upnp-org:device:Printer:1")
        #expect(SonyDiscovery.location(inAnswer: printer) == nil)
        #expect(SonyDiscovery.searchRequest.contains("ST: urn:schemas-sony-com:service:DigitalImaging:1\r\n"))
    }

    @Test("The addresses asked: each network's hosts up to a /24, never this device's own, nor a tunnel's or a /32's")
    func addresses() throws {
        func net(_ interface: String, _ dotted: String, _ prefix: Int) throws -> LocalIPv4 {
            try #require(LocalIPv4(interface: interface, dotted, prefix: prefix))
        }
        let lan = SonyDiscovery.hosts(on: [try net("en0", "192.0.2.163", 24)])
        #expect(lan.count == 253 && lan.first == "192.0.2.1" && lan.last == "192.0.2.254" && !lan.contains("192.0.2.163"))
        // A Mac on one network twice (Wi-Fi and Ethernet): each address once, neither of its own.
        let twice = SonyDiscovery.hosts(on: [try net("en10", "192.0.2.27", 24), try net("en0", "192.0.2.163", 24)])
        #expect(twice.count == 252 && !twice.contains("192.0.2.27") && !twice.contains("192.0.2.163"))
        #expect(SonyDiscovery.hosts(on: [try net("en0", "192.0.2.9", 16)]).count == 253, "a /16 is asked as its /24")
        #expect(SonyDiscovery.hosts(on: [try net("en14", "172.27.250.14", 30)]) == ["172.27.250.13"])
        #expect(SonyDiscovery.hosts(on: [try net("en14", "172.27.250.14", 31)]) == ["172.27.250.15"])
        #expect(SonyDiscovery.hosts(on: [try net("bridge100", "172.20.10.1", 28)]).count == 13, "an iPhone's hotspot")
        #expect(SonyDiscovery.hosts(on: [try net("pdp_ip0", "10.70.3.4", 24), try net("utun5", "100.64.0.1", 10),
                                         try net("en0", "169.254.3.4", 16), try net("en5", "10.1.1.1", 32)]).isEmpty)
    }

    @Test("A camera on the network found by asking each address for its description", .timeLimit(.minutes(1)))
    func foundBySweep() async throws {
        let camera = try await DescriptionServer.start(pages: ["/DigitalImagingDesc.xml": Self.fx5Description])
        defer { camera.stop() }
        let nobody = try await DescriptionServer.start(pages: [:])  // a web server that isn't a camera's
        defer { nobody.stop() }
        var found: [SonyNetworkCamera] = []
        for await one in SonyDiscovery.search(hosts: ["127.0.0.1"], port: camera.port, multicast: false, seconds: 2) {
            found.append(one)
        }
        #expect(found == [SonyNetworkCamera(host: "127.0.0.1", model: "ILME-FX5", firmware: "1.00", needsLogin: true)])
        var none = 0
        for await _ in SonyDiscovery.search(hosts: ["127.0.0.1"], port: nobody.port, multicast: false, seconds: 2) {
            none += 1
        }
        #expect(none == 0)
    }

    @Test("One list: a Sony as Tiles names it, with its model and login; a Blackmagic camera on a network, not a cable")
    func oneList() throws {
        let fx5 = NetworkCamera(SonyNetworkCamera(host: "192.0.2.254", model: "ILME-FX5", firmware: "1.00", needsLogin: true))
        #expect(fx5 == NetworkCamera(host: "192.0.2.254", maker: .sony, name: "FX5", model: "ILME-FX5", needsLogin: true))
        let wifi = BlackmagicAdverts.Advert(serial: "1A2B3C", product: "PYXIS 12K", interface: "en0", link: .wifi)
        let wired = BlackmagicAdverts.Advert(serial: "1A2B3C", product: "PYXIS 12K", interface: "en10", link: .wired)
        let cable = BlackmagicAdverts.Advert(serial: "4D5E6F", product: "PYXIS 6K", interface: "en14", link: .wired)
        let unasked = BlackmagicAdverts.Advert(serial: "778899", product: "URSA Cine 12K LF", interface: "en0", link: .wifi)
        let addresses = [try #require(LocalIPv4(interface: "en0", "192.0.2.163", prefix: 24)),
                         try #require(LocalIPv4(interface: "en10", "192.0.2.27", prefix: 24)),
                         try #require(LocalIPv4(interface: "en14", "172.27.250.14", prefix: 30))]
        let resolved = [BlackmagicAdverts.key(wifi): "192.0.2.40", BlackmagicAdverts.key(wired): "192.0.2.40",
                        BlackmagicAdverts.key(cable): "172.27.250.13"]
        // The camera on Wi-Fi and Ethernet once; the one on a cable is the USB list's; one not asked yet waits.
        #expect(NetworkCameras.blackmagic([wifi, wired, cable, unasked], resolved: resolved, among: addresses)
                == [NetworkCamera(host: "192.0.2.40", maker: .blackmagic, name: "PYXIS 12K")])
    }

    @Test("A camera slow to answer its first ask is asked again, and found in the same search", .timeLimit(.minutes(1)))
    func askedAgain() async throws {
        // Its first answer comes after the first wait (1.5 s) runs out (found only by a second search); its second
        // at once.
        let camera = try await DescriptionServer.start(pages: ["/DigitalImagingDesc.xml": Self.fx5Description],
                                                       firstAnswerAfter: 2.5)
        defer { camera.stop() }
        var found: [String] = []
        for await one in SonyDiscovery.search(hosts: ["127.0.0.1"], port: camera.port, multicast: false, seconds: 2) {
            found.append(one.model)
        }
        #expect(found == ["ILME-FX5"])
    }

    @Test("A camera that answered the search: its description found from the dd.xml it points at", .timeLimit(.minutes(1)))
    func describedFromItsAnswer() async throws {
        let camera = try await DescriptionServer.start(pages: ["/dd.xml": Self.fx5DeviceDescription,
                                                               "/DigitalImagingDesc.xml": Self.fx5Description])
        defer { camera.stop() }
        let location = try #require(URL(string: "http://127.0.0.1:\(camera.port)/dd.xml"))
        let found = await SonyDiscovery.describe(location, session: URLSession(configuration: .ephemeral))
        #expect(found?.model == "ILME-FX5" && found?.host == "127.0.0.1" && found?.needsLogin == true)
    }
}

/// A camera's UPnP description server on 127.0.0.1: a GET answered by its path, anything else 404.
final class DescriptionServer: @unchecked Sendable {
    private let listener: NWListener
    private let pages: [String: String]
    private let queue = DispatchQueue(label: "description-server")
    private(set) var port: UInt16 = 0
    /// Seconds before the first request is answered; every later one at once. On the queue only.
    private var firstAnswerAfter: Double

    private init(pages: [String: String], firstAnswerAfter: Double) throws {
        listener = try LoopbackListener.make()
        self.pages = pages
        self.firstAnswerAfter = firstAnswerAfter
    }

    static func start(pages: [String: String], firstAnswerAfter: Double = 0) async throws -> DescriptionServer {
        let server = try DescriptionServer(pages: pages, firstAnswerAfter: firstAnswerAfter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
            server.listener.stateUpdateHandler = { [weak server] state in
                switch state {
                case .ready:
                    server?.port = server?.listener.port?.rawValue ?? 0
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection, received: Data = Data()) {
        if received.isEmpty { connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, _ in
            guard let self else { return }
            let request = received + (data ?? Data())
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || data == nil { connection.cancel() } else { self.serve(connection, received: request) }
                return
            }
            let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = pages[path]
            let response = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/xml\r\n"
                + "Content-Length: \((body ?? "").utf8.count)\r\nConnection: close\r\n\r\n\(body ?? "")"
            let delay = firstAnswerAfter
            firstAnswerAfter = 0
            queue.asyncAfter(deadline: .now() + delay) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
