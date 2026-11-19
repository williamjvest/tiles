import Foundation
import Testing
@testable import CameraCore

/// A real camera's backend that only counts how often it's asked to connect.
private actor CountingBackend: CameraBackend {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation
    private(set) var connects = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: CameraState.self) }

    func connect() async {
        connects += 1
        var state = CameraState()
        state.connection = .connected
        continuation.yield(state)
    }
    func disconnect() async {}
    func send(_ command: CameraCommand) async {}
}

@Suite("Terms of Use", .serialized)
@MainActor
struct TermsOfUseTests {
    private func freshDefaults() -> UserDefaults {
        let name = "TermsOfUseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The repo's root, from this file: Packages/CameraKit/Tests/CameraCoreTests/.
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Agreed once, kept with its version and date, and an older version's agreement doesn't count")
    func acceptance() {
        let defaults = freshDefaults()
        #expect(!TermsOfUse.isAccepted(in: defaults))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        TermsOfUse.accept(in: defaults, at: when)
        #expect(TermsOfUse.isAccepted(in: defaults))
        #expect(TermsOfUse.acceptance(in: defaults) == .init(version: TermsOfUse.version, acceptedAt: when))

        let old = try? JSONEncoder().encode(TermsOfUse.Acceptance(version: TermsOfUse.version - 1, acceptedAt: when))
        defaults.set(old, forKey: TermsOfUse.acceptanceKey)
        #expect(!TermsOfUse.isAccepted(in: defaults), "a new version is asked again")
    }

    @Test("Held for the terms, a real camera doesn't connect, even back from the background; agreeing connects it", .timeLimit(.minutes(1)))
    func holdsRealCameras() async throws {
        let backend = CountingBackend()
        let real = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "10.0.0.9"),
                               connection: .blackmagic(BlackmagicConnection(host: "10.0.0.9")))
        let demo = SavedCamera(slot: CameraSlot(label: "D", color: .blue, host: "demo"), demoBody: .fx3)
        let defaults = freshDefaults()
        let store = DashboardStore(
            cameras: [real, demo], pages: [CameraPage(name: "All", showsAllCameras: true)], defaults: defaults,
            startCameras: true, holdsRealCameras: true,
            makeBackend: { camera, password in
                camera.connection.demoBody == nil ? backend : DashboardStore.demoOnlyBackend(camera, password: password)
            })
        #expect(store.holdsRealCameras)

        // The demo runs; the real camera is never asked to connect.
        for _ in 0..<300 where store.camera(demo.slot.id)?.state.connection != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.camera(demo.slot.id)?.state.connection == .connected)
        store.suspendAll()
        store.resumeAll()
        _ = store.addCamera(label: "B", color: .green, host: "10.0.0.10",
                            connection: .blackmagic(BlackmagicConnection(host: "10.0.0.10")))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await backend.connects == 0, "a camera held for the terms mustn't connect")
        #expect(store.termsAcceptance == nil)

        store.agreeToTerms()
        #expect(!store.holdsRealCameras)
        #expect(TermsOfUse.isAccepted(in: defaults))
        #expect(store.termsAcceptance?.version == TermsOfUse.version)
        for _ in 0..<300 where await backend.connects < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await backend.connects == 2, "both real cameras connect once agreed")
    }

    @Test("A store that isn't held connects as before")
    func notHeldByDefault() {
        let store = DashboardStore(cameras: [], pages: [CameraPage(name: "All", showsAllCameras: true)], startCameras: false)
        #expect(!store.holdsRealCameras)
    }

    @Test("The text has every section, Florida law, and the sheet's points word for word")
    func text() {
        let paragraphs = TermsOfUse.paragraphs
        #expect(paragraphs.count == 11)
        #expect(paragraphs.first?.hasPrefix("**1. Who we are.**") == true)
        #expect(paragraphs.last?.hasPrefix("**11. Apple.**") == true)
        let all = paragraphs.joined(separator: "\n")
        #expect(all.contains("Toldwell LLC, 9056 136th St., Seminole, Florida 33776"))
        #expect(all.contains("+1 423 650 1231") && all.contains("william@toldwell.com"))
        #expect(all.contains("laws of the State of Florida") && all.contains("Pinellas County, Florida"))
        #expect(!all.contains("["), "no blanks left to fill")
        // The sheet's Sony warranty point is section 4's sentence.
        let sony = paragraphs[3]
        #expect(sony.localizedCaseInsensitiveContains(TermsOfUse.sonyWarranty))
        #expect(sony.contains("military activities such as intelligence, surveillance or reconnaissance"))
    }

    @Test("The repo's LICENSE and NOTICE match what the app shows")
    func repoFilesMatch() throws {
        let licence = try String(contentsOf: repo.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(licence == TermsOfUse.license)
        #expect(licence.contains("Copyright (c) 2026 Toldwell LLC"))
        let notice = try String(contentsOf: repo.appendingPathComponent("NOTICE"), encoding: .utf8)
        #expect(notice.contains(TermsOfUse.acknowledgements.trimmingCharacters(in: .whitespacesAndNewlines)),
                "NOTICE carries the app's third-party notices")
        #expect(words(notice).contains(words(TermsOfUse.sonyWarranty)), "and Sony's warranty term, as the app has it")
        for notice in ["libssh2 1.11.1", "OpenSSL 3.5.9", "Apache License 2.0", "David Lidström"] {
            #expect(TermsOfUse.acknowledgements.contains(notice), "\(notice)")
        }
    }
}
