import Foundation
import Testing
@testable import CameraCore

/// A setup saved by a real build reads back, and saves, the same in this one.
///
/// - venice2-dashboard-build48: what an earlier build saved for a VENICE 2 it had seen (a FakeVeniceCamera:
///   model, the tiles it offers, its five outputs), on the automatic page and on a customized, linked one.
/// - camera-dashboard: an FX3 on USB and a BURANO over HaLow, a customized page of 43 tiles (two-camera setup).
@Suite("Saved setups")
struct SavedSetupTests {
    static func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("fixtures/\(name).json"))
    }

    /// Every camera survives (a camera this build can't read is left out without a word, `Lenient`), and saving it
    /// again writes the same JSON: no key added, dropped or changed.
    @MainActor @Test("Reads back and saves unchanged", arguments: ["venice2-dashboard-build48-2026-10-27", "camera-dashboard-2026-10-27"])
    func roundTrip(name: String) throws {
        let original = try Self.fixture(name)
        let suite = "camerakit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(original, forKey: DashboardStore.storageKey)

        let store = DashboardStore.load(from: defaults, startCameras: false)
        let saved = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let cameras = try #require(saved["cameras"] as? [[String: Any]])
        #expect(store.cameras.count == cameras.count)
        #expect(store.pages.count == (saved["pages"] as? [Any])?.count)

        // Any change saves the whole setup: select the page that was current.
        store.selectPage(try #require(store.currentPageID))
        let again = try #require(defaults.data(forKey: DashboardStore.storageKey))
        // All as it was but the version, which says this build's migrations ran (v9–v11 reset untouched v4–v6
        // layouts; these fixtures have none to reset).
        let before = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let after = try #require(JSONSerialization.jsonObject(with: again) as? [String: Any])
        #expect(after["version"] as? Int == 11)
        #expect(NSDictionary(dictionary: before.filter { $0.key != "version" })
                == NSDictionary(dictionary: after.filter { $0.key != "version" }))
    }

    @MainActor @Test("The VENICE 2 keeps its connection, its outputs and its customised linked page")
    func venice() throws {
        let suite = "camerakit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try Self.fixture("venice2-dashboard-build48-2026-10-27"), forKey: DashboardStore.storageKey)

        let store = DashboardStore.load(from: defaults, startCameras: false)
        let camera = try #require(store.cameras.first)
        let saved = try #require(store.savedCamera(camera.id))
        guard case .venice = saved.connection else { Issue.record("not a VENICE connection: \(saved.connection)"); return }
        #expect(saved.lastSeen?.model == "MPC-3628")
        #expect(saved.lastSeen?.outputs?.count == 5)
        let page = try #require(store.pages.first { $0.name == "A VENICE" })
        #expect(page.layout?.widgets.count == 26)
        #expect(page.linkingOn == true)
        // Nothing BURANO-only came with this build's new tiles.
        let offered = saved.lastSeen?.offered ?? []
        #expect(offered.isDisjoint(with: [.ndMode, .tally, .call, .colorGamut, .cameraMenu]))
    }
}
