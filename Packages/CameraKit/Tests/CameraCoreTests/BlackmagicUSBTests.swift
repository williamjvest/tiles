@testable import CameraCore
import Foundation
import Testing

/// A Blackmagic camera on a USB cable: where its cable reaches it (`BlackmagicUSBLink`), from this device's addresses.
@Suite struct BlackmagicUSBTests {
    private func ip(_ interface: String, _ dotted: String, _ prefix: Int) -> LocalIPv4 {
        LocalIPv4(interface: interface, dotted, prefix: prefix)!
    }

    @Test("The camera is the other address of its cable's pair, whichever this device has")
    func pair() {
        let lan = ip("en0", "192.168.1.20", 24)
        #expect(BlackmagicUSBLink.find(on: "en14", among: [lan, ip("en14", "172.27.250.14", 30)]) == .at("172.27.250.13"))
        #expect(BlackmagicUSBLink.find(on: "en14", among: [ip("en14", "172.27.250.13", 30)]) == .at("172.27.250.14"))
        #expect(BlackmagicUSBLink.find(on: "en7", among: [ip("en7", "10.9.8.6", 31)]) == .at("10.9.8.7"))
    }

    @Test("Its link still coming up: no interface yet, no address on it, or only one this device gave itself")
    func starting() {
        #expect(BlackmagicUSBLink.find(on: nil, among: [ip("en0", "192.168.1.20", 24)]) == .starting)
        #expect(BlackmagicUSBLink.find(on: "en14", among: [ip("en0", "192.168.1.20", 24)]) == .starting)
        #expect(BlackmagicUSBLink.find(on: "en14", among: [ip("en14", "169.254.17.3", 16)]) == .starting)
    }

    @Test("Two cables with the same pair: refused, as a request could reach either camera")
    func shared() {
        let both = [ip("en14", "172.27.250.14", 30), ip("en15", "172.27.250.14", 30)]
        #expect(BlackmagicUSBLink.find(on: "en14", among: both) == .problem(.sharedAddresses))
        #expect(BlackmagicUSBLink.find(on: "en15", among: both) == .problem(.sharedAddresses))
        // A wider network around those addresses elsewhere isn't: the cable's pair is the closer route.
        let wider = [ip("en14", "172.27.250.14", 30), ip("en0", "172.27.0.5", 16)]
        #expect(BlackmagicUSBLink.find(on: "en14", among: wider) == .at("172.27.250.13"))
    }

    @Test("Not a two-address link: the camera's address on it can't be told")
    func unknownLink() {
        #expect(BlackmagicUSBLink.find(on: "en14", among: [ip("en14", "192.168.7.2", 24)]) == .problem(.unknownLink))
        // A /30's network address isn't one of its two.
        #expect(BlackmagicUSBLink.find(on: "en14", among: [ip("en14", "172.27.250.12", 30)]) == .problem(.unknownLink))
    }

    @Test("Waiting for the link: the camera once it's up, a problem at once, or out of patience")
    func waiting() async throws {
        let looks = Looks([.starting, .starting, .at("172.27.250.13")])
        let found = try await BlackmagicUSBLink.waitForAddress(patience: .seconds(5), interval: .milliseconds(10)) { looks.next() }
        #expect(found == "172.27.250.13")
        await #expect(throws: BlackmagicUSBLink.Problem.notConnected) {
            try await BlackmagicUSBLink.waitForAddress(patience: .seconds(5), interval: .milliseconds(10)) {
                .problem(.notConnected)
            }
        }
        await #expect(throws: BlackmagicUSBLink.Problem.linkNotUp) {
            try await BlackmagicUSBLink.waitForAddress(patience: .milliseconds(100), interval: .milliseconds(10)) { .starting }
        }
    }

    @Test("Addresses: dotted both ways, and nonsense refused")
    func dotted() {
        #expect(LocalIPv4.value("172.27.250.13") == 0xAC1B_FA0D)
        #expect(LocalIPv4.dotted(0xAC1B_FA0D) == "172.27.250.13")
        #expect(LocalIPv4.value("256.1.1.1") == nil)
        #expect(LocalIPv4.value("1.2.3") == nil)
        #expect(LocalIPv4.value("a.b.c.d") == nil)
        #expect(ip("en14", "172.27.250.14", 30).netmask == 0xFFFF_FFFC)
        #expect(!LocalAddresses.ipv4ByInterface().contains { $0.address >> 24 == 127 })
    }

    @Test("Saved as usb:<serial> in lower case, shown by its ends; Remote Control's port on the address it's found at")
    func saved() {
        #expect(BlackmagicUSBSerial.normalised("0123456789ABCDEF0123456789ABCDEF") == "0123456789abcdef0123456789abcdef")
        #expect(USBCameraAddress.label(serial: "0123456789abcdef0123456789abcdef") == "0123…cdef")
        #expect(USBCameraAddress.label(serial: "5432109") == "5432109")
        #expect(USBCameraAddress.display("usb:0123456789abcdef0123456789abcdef") == "USB")
        let remote = BlackmagicConnection(host: "usb:0123456789abcdef0123456789abcdef", remoteControl: true)
        #expect(remote.address(at: "172.27.250.13") == "172.27.250.13:444")
        #expect(BlackmagicConnection(host: remote.host).address(at: "172.27.250.13") == "172.27.250.13")
    }

    // MARK: Through Bonjour, as an iPhone or iPad finds it

    private let pyxisTXT = ["txtvers": "1", "camera name": "A", "capabilities": "cameraControl", "device name": "PYXIS 12K",
                            "product id": "BEFB", "product name": "PYXIS 12K", "release version": "10.3.1",
                            "unique id": "0123456789ABCDEF0123456789ABCDEF"]

    @Test("An advert: a camera Tiles can control, with its unique id as the serial a Mac sees")
    func advert() {
        let advert = BlackmagicAdverts.Advert(txt: pyxisTXT, interface: "en2", isWired: true)
        #expect(advert?.serial == "0123456789abcdef0123456789abcdef")
        #expect(advert?.product == "PYXIS 12K")
        #expect(advert?.host == "usb:0123456789abcdef0123456789abcdef")
        var printer = pyxisTXT
        printer["capabilities"] = nil
        #expect(BlackmagicAdverts.Advert(txt: printer, interface: "en0", isWired: false) == nil)
        var anonymous = pyxisTXT
        anonymous["unique id"] = nil
        #expect(BlackmagicAdverts.Advert(txt: anonymous, interface: "en2", isWired: true) == nil)
        var several = pyxisTXT
        several["capabilities"] = "mediaManagement,cameraControl"
        #expect(BlackmagicAdverts.Advert(txt: several, interface: "en2", isWired: true) != nil)
    }

    @Test("On a cable: a wired advert on a two-address link, one row a camera, Wi-Fi and wired networks left out")
    func onCables() {
        let addresses = [ip("en0", "192.168.1.20", 24), ip("en2", "172.27.250.14", 30), ip("en3", "10.0.0.8", 24)]
        let cable = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "en2", isWired: true)
        let wifi = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "en0", isWired: false)
        let lan = BlackmagicAdverts.Advert(serial: "BB02", product: "URSA Cine 12K", interface: "en3", isWired: true)
        #expect(BlackmagicAdverts.onCables([wifi, cable, lan, cable], among: addresses) == [cable])
        #expect(BlackmagicUSBLink.isCable("en2", among: addresses))
        #expect(!BlackmagicUSBLink.isCable("en3", among: addresses))
        #expect(!BlackmagicUSBLink.isCable("en2", among: [ip("en2", "169.254.3.4", 16)]))
    }

    @Test("Found by its adverts: on its cable, starting while the browse is young, then not connected")
    func foundByAdverts() {
        let addresses = [ip("en0", "192.168.1.20", 24), ip("en2", "172.27.250.14", 30)]
        let cable = BlackmagicAdverts.Advert(serial: "0123456789abcdef0123456789abcdef", product: "PYXIS 12K", interface: "en2", isWired: true)
        let wifi = BlackmagicAdverts.Advert(serial: cable.serial, product: "PYXIS 12K", interface: "en0", isWired: false)
        let serial = "0123456789ABCDEF0123456789ABCDEF"
        #expect(BlackmagicUSBLink.find(serial: serial, adverts: [wifi, cable], lookingFor: .seconds(30), among: addresses)
                == .at("172.27.250.13"))
        #expect(BlackmagicUSBLink.find(serial: serial, adverts: [], lookingFor: .seconds(1), among: addresses) == .starting)
        #expect(BlackmagicUSBLink.find(serial: serial, adverts: [], lookingFor: .seconds(30), among: addresses)
                == .problem(.notConnected))
        // On the network only, the camera isn't on a cable.
        #expect(BlackmagicUSBLink.find(serial: serial, adverts: [wifi], lookingFor: .seconds(30), among: addresses)
                == .problem(.notConnected))
        // Its advert there before this device has its address on the cable.
        #expect(BlackmagicUSBLink.find(serial: serial, adverts: [cable], lookingFor: .seconds(30),
                                       among: [ip("en2", "169.254.9.9", 16)]) == .starting)
    }

    @Test("A cable's link the system calls neither wired nor Wi-Fi still counts, by its two addresses; a cellular one doesn't")
    func otherKindOfLink() {
        let addresses = [ip("en0", "192.168.1.20", 24), ip("anpi0", "172.27.250.14", 30)]
        let usb = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "anpi0", link: .other)
        let cellular = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "anpi0", link: .cellular)
        #expect(BlackmagicAdverts.onCables([usb], among: addresses) == [usb])
        #expect(BlackmagicAdverts.onCables([cellular], among: addresses).isEmpty)
        #expect(BlackmagicUSBLink.find(serial: "aa01", adverts: [usb], lookingFor: .seconds(30), among: addresses)
                == .at("172.27.250.13"))
        // Not a two-address link, nor this iPhone's Personal Hotspot: listed nowhere, and said as such.
        let wide = [ip("en5", "10.20.0.8", 24)]
        let lan = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "en5", link: .other)
        #expect(BlackmagicAdverts.onCables([lan], among: wide).isEmpty)
        #expect(BlackmagicUSBLink.find(serial: "aa01", adverts: [lan], lookingFor: .seconds(30), among: wide)
                == .problem(.unknownLink))
    }

    @Test("On an iPhone's Personal Hotspot (172.20.10.1/28): listed, and found at the address its advert resolves to")
    func onPersonalHotspot() {
        let addresses = [ip("en0", "192.168.1.20", 24), ip("bridge100", "172.20.10.1", 28)]
        #expect(addresses[1].isPersonalHotspot)
        #expect(!ip("bridge100", "172.20.10.2", 28).isPersonalHotspot, "a hotspot's client, not the hotspot")
        #expect(!ip("en3", "172.20.10.1", 24).isPersonalHotspot)
        // Whatever kind the system calls the hotspot's interface; never cellular.
        for link in [BlackmagicAdverts.Link.other, .wired, .wifi] {
            let camera = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "bridge100", link: link)
            #expect(BlackmagicAdverts.onCables([camera], among: addresses) == [camera])
        }
        let cellular = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "bridge100", link: .cellular)
        #expect(BlackmagicAdverts.onCables([cellular], among: addresses).isEmpty)
        let camera = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "bridge100", link: .other)
        // Its address still being asked for: starting, however long it's been browsing.
        #expect(BlackmagicUSBLink.find(serial: "aa01", adverts: [camera], lookingFor: .seconds(30), among: addresses)
                == .starting)
        let resolved = [BlackmagicAdverts.key(camera): "172.20.10.2"]
        #expect(BlackmagicUSBLink.find(serial: "AA01", adverts: [camera], lookingFor: .seconds(30), among: addresses,
                                       resolved: resolved) == .at("172.20.10.2"))
        // A cable's two-address link still wins where the camera has both.
        let cable = BlackmagicAdverts.Advert(serial: "AA01", product: "PYXIS 12K", interface: "en2", link: .wired)
        #expect(BlackmagicUSBLink.find(serial: "aa01", adverts: [camera, cable], lookingFor: .seconds(30),
                                       among: addresses + [ip("en2", "172.27.250.14", 30)]) == .at("172.27.250.13"))
        #expect(BlackmagicAdverts.describe(browsing: "ready", adverts: [camera], addresses: addresses, resolved: resolved)
                .contains("PYXIS 12K …aa01 on bridge100 (other) at 172.20.10.2"))
    }

    @Test("What the browse sees, for the Activity Log: each advert's interface and kind, and this device's addresses")
    func describeForTheLog() {
        let adverts = [BlackmagicAdverts.Advert(serial: "A3F12D7E9B054C81D6E2F5A890C3B472", product: "PYXIS 12K",
                                                interface: "en5", link: .other)]
        let text = BlackmagicAdverts.describe(browsing: "ready", adverts: adverts,
                                              addresses: [ip("en0", "192.168.1.20", 24), ip("en5", "169.254.7.9", 16)])
        #expect(text == "Bonjour browse ready; camera adverts: PYXIS 12K …b472 on en5 (other); this device's IPv4: "
                + "en0 192.168.1.20/24, en5 169.254.7.9/16")
        #expect(BlackmagicAdverts.describe(browsing: "waiting(-65555: NoAuth)", adverts: [], addresses: [])
                == "Bonjour browse waiting(-65555: NoAuth); no camera adverts; this device's IPv4: none")
    }

    #if os(macOS)
    @Test("A serial that isn't on this Mac's USB: not connected")
    func notOnThisMac() {
        #expect(BlackmagicUSBLink.find(serial: "0000not0a0camera0000") == .problem(.notConnected))
    }
    #endif
}

/// Each look's finding in turn, the last one from then on.
private final class Looks {
    private var findings: [BlackmagicUSBLink.Finding]
    init(_ findings: [BlackmagicUSBLink.Finding]) { self.findings = findings }
    func next() -> BlackmagicUSBLink.Finding { findings.count > 1 ? findings.removeFirst() : findings[0] }
}
