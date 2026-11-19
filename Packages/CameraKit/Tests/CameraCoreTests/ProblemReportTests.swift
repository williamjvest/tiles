import Foundation
import Testing
@testable import CameraCore

@MainActor
@Suite("Problem report")
struct ProblemReportTests {
    @Test("Each camera: what it is, how Tiles reaches it, its state; never a user name, password or fingerprint")
    func fromStore() {
        let sonyID = UUID(), blackmagicID = UUID()
        let sony = SavedCamera(slot: CameraSlot(id: sonyID, label: "A", color: .red, host: "192.0.2.20"),
                               connection: .sony(SonyConnection(username: "admin", trustedFingerprint: "SHA256:kexL4")))
        let blackmagic = SavedCamera(
            slot: CameraSlot(id: blackmagicID, label: "B", color: .blue, host: "192.0.2.30"),
            connection: .blackmagic(BlackmagicConnection(host: "192.0.2.30", useHTTPS: true,
                                                         pinnedCertificateFingerprint: "AB:CD", username: "operator")))
        var connected = CameraState()
        connected.connection = .connected
        connected.make = .sony
        connected.model = "ILME-FX6V"
        connected.latencyMilliseconds = 38
        connected.recording.failure = "The camera didn't start recording."
        var failed = CameraState()
        failed.connection = .failed("The camera refused the login.")
        failed.make = .blackmagic
        let credentials = InMemoryCredentialStore()
        credentials.setPassword("hunter2", for: sonyID)
        credentials.setPassword("swordfish", for: blackmagicID)
        let store = DashboardStore(cameras: [sony, blackmagic], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                   startCameras: false, initialStates: [sonyID: connected, blackmagicID: failed],
                                   credentials: credentials)
        store.controlsLocked = true

        let report = ProblemReport(store: store, whatHappened: "REC didn't start on A.", app: "Tiles 1.0 (1)",
                                   device: "iPad16,1, iPadOS 26.1", controlAPIOn: true,
                                   log: "12:00:00.000 192.0.2.20: connected")

        #expect(report.cameras.map(\.name) == ["Sony FX6V (ILME-FX6V)", "Blackmagic camera"])
        #expect(report.cameras.map(\.link) == ["Camera Remote (Access Authentication), 192.0.2.20",
                                               "Blackmagic REST (HTTPS), 192.0.2.30"])
        #expect(report.cameras.map(\.state) == ["Connected, 38 ms. REC: The camera didn't start recording.",
                                                "Couldn't connect: The camera refused the login."])
        #expect(report.settings == ["Controls locked", "Control API on"])
        #expect(report.subject == "Tiles problem report: FX6V, B")
        for secret in ["admin", "operator", "hunter2", "swordfish", "SHA256", "AB:CD"] {
            #expect(!report.text.contains(secret), "\(secret) is in the report")
        }
    }

    @Test("A camera that has never connected says so, and one named by its model alone says its maker once")
    func names() {
        var venice = CameraState()
        venice.make = .sony
        venice.model = "MPC-3628"
        #expect(ProblemReport.state(CameraState()) == "Not connected.")
        let id = UUID()
        let store = DashboardStore(
            cameras: [SavedCamera(slot: CameraSlot(id: id, label: "V", color: .green, host: "192.0.2.40"),
                                  connection: .venice(VeniceConnection(host: "192.0.2.40")))],
            pages: [CameraPage(name: "All", showsAllCameras: true)], startCameras: false, initialStates: [id: venice])
        let report = ProblemReport(store: store, whatHappened: "", app: "Tiles", device: "Mac15,3, macOS 26.1", log: "")
        #expect(report.cameras.first?.name == "Sony VENICE 2 (MPC-3628)")
        #expect(report.cameras.first?.link == "VENICE Web Remote, 192.0.2.40")
    }

    @Test("The email's body has everything but the log, which is attached; Copy has all of it")
    func bodyAndText() {
        let report = ProblemReport(whatHappened: "  The B camera dropped twice.\n", app: "Tiles 1.0 (1)",
                                   device: "iPhone17,1, iOS 26.1",
                                   cameras: [.init(label: "B", name: "Blackmagic PYXIS 12K", model: "PYXIS 12K",
                                                   link: "Blackmagic REST, USB", state: "Not connected.")],
                                   settings: ["Test Mode on"], log: "one\ntwo\nthree")
        #expect(report.summary == """
            The B camera dropped twice.

            Tiles 1.0 (1) on iPhone17,1, iOS 26.1

            Cameras:
            B: Blackmagic PYXIS 12K, Blackmagic REST, USB. Not connected.

            Test Mode on.

            The Activity Log is attached (3 lines).
            """)
        #expect(report.text.hasSuffix("Test Mode on.\n\nActivity Log:\none\ntwo\nthree"))

        let blank = ProblemReport(whatHappened: " ", app: "Tiles", device: "Mac15,3, macOS 26.1", cameras: [],
                                  settings: [], log: "")
        #expect(blank.summary.hasPrefix("(Nothing written about what happened.)"))
        #expect(blank.summary.hasSuffix("The Activity Log is empty."))
        #expect(blank.subject == "Tiles problem report")
    }

    @Test("A mailto: link carries the report and as much of the log's end as fits")
    func mailto() throws {
        let log = (1 ... 400).map { "12:00:00.000 192.0.2.20: line \($0)" }.joined(separator: "\n")
        let report = ProblemReport(whatHappened: "A+B & C?", app: "Tiles 1.0 (1)", device: "Mac15,3, macOS 26.1",
                                   cameras: [], settings: [], log: log)
        let url = try #require(report.mailto(maxLength: 2000))
        #expect(url.absoluteString.count <= 2000)
        #expect(url.absoluteString.hasPrefix("mailto:\(Support.email)?"))
        #expect(url.absoluteString.contains("A%2BB"), "a + would reach the mail app as a space")
        let body = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value)
        #expect(body.hasPrefix("A+B & C?"))
        #expect(body.hasSuffix("line 400"))
        #expect(!body.contains("line 1\n"))
        #expect(body.contains("Activity Log, its last "))

        let short = ProblemReport(whatHappened: "x", app: "Tiles", device: "d", cameras: [], settings: [], log: "a\nb")
        let whole = try #require(short.mailto()?.absoluteString.removingPercentEncoding)
        #expect(whole.hasSuffix("Activity Log:\na\nb"))
    }
}
