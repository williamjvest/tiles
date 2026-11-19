import Foundation
import Testing
@testable import CameraCore

/// The ND tile's − + step buttons as an option set in edit mode: `PageWidget.showsStep`, nil until
/// switched, which is `stepByDefault`.
@Suite("ND step option")
struct NDStepOptionTests {
    @Test("A widget nobody has switched reads stepByDefault, and saves without the key")
    func unswitched() throws {
        let widget = PageWidget(kind: .ndPreset, cameraID: UUID(), x: 0, y: 0, w: 2, h: 2)
        #expect(widget.showsStep == nil)
        #expect(widget.stepButtons == PageWidget.stepByDefault)
        let json = String(decoding: try JSONEncoder().encode(widget), as: UTF8.self)
        #expect(!json.contains("showsStep"))
        let back = try JSONDecoder().decode(PageWidget.self, from: Data(json.utf8))
        #expect(back == widget)
    }

    @Test("A switched widget keeps its choice through a save")
    func switched() throws {
        var widget = PageWidget(kind: .ndPreset, cameraID: UUID(), x: 0, y: 0, w: 2, h: 2)
        widget.showsStep = !PageWidget.stepByDefault
        let back = try JSONDecoder().decode(PageWidget.self, from: JSONEncoder().encode(widget))
        #expect(back.stepButtons == !PageWidget.stepByDefault)
    }

    /// On an automatic page the switch makes the layout explicit, as any edit does, and the choice is saved.
    @MainActor @Test("setWidgetStep switches the ND tile and is saved; other kinds are left alone")
    func store() throws {
        let suite = "camerakit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DashboardStore.load(from: defaults, startCameras: false)
        let camera = store.addCamera(label: "A", color: .red, host: "192.0.2.10", demoBody: .venice2)
        let page = try #require(store.pages.first)
        store.materializeLayout(page.id)
        let nd = try #require(store.pages[0].layout?.widgets.first { $0.kind == .ndPreset && $0.cameraID == camera.id })
        #expect(nd.stepButtons == PageWidget.stepByDefault)

        store.setWidgetStep(page.id, nd.id, on: false)
        #expect(store.pages[0].layout?.widgets.first { $0.id == nd.id }?.stepButtons == false)
        // Done keeps it: a layout with a switched tile isn't the automatic arrangement.
        store.finishEditing(page.id)
        #expect(store.pages[0].layout?.widgets.first { $0.id == nd.id }?.stepButtons == false)
        let reloaded = DashboardStore.load(from: defaults, startCameras: false)
        #expect(reloaded.pages[0].layout?.widgets.first { $0.id == nd.id }?.stepButtons == false)

        store.setWidgetStep(page.id, nd.id, on: true)
        #expect(store.pages[0].layout?.widgets.first { $0.id == nd.id }?.stepButtons == true)

        let other = try #require(store.pages[0].layout?.widgets.first { $0.kind != .ndPreset })
        store.setWidgetStep(page.id, other.id, on: false)
        #expect(store.pages[0].layout?.widgets.first { $0.id == other.id }?.showsStep == nil)
    }
}
