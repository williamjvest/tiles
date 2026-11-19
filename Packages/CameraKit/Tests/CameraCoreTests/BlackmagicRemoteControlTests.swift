import Foundation
import Testing
@testable import CameraCore

/// A Blackmagic camera through its Remote Control: the remote password on port 444 over HTTPS, as the camera serves it
/// with or without Network Access.
@Suite struct BlackmagicRemoteControlTests {
    private func remote(_ host: String) -> BlackmagicConnection {
        BlackmagicConnection(host: host, remoteControl: true)
    }

    @Test("Remote Control connects to the camera's port 444, unless the address names a port")
    func address() {
        #expect(remote("192.0.2.105").address == "192.0.2.105:444")
        #expect(remote("pyxis-12k.local").address == "pyxis-12k.local:444")
        #expect(remote("192.0.2.105:8444").address == "192.0.2.105:8444")
        #expect(remote("2001:db8::105").address == "[2001:db8::105]:444")
        #expect(remote("[2001:db8::105]").address == "[2001:db8::105]:444")
        #expect(remote("[2001:db8::105]:8444").address == "[2001:db8::105]:8444")
        #expect(BlackmagicConnection(host: "192.0.2.105").address == "192.0.2.105")
    }

    @Test("Remote Control's login is Blackmagic's fixed user name, over HTTPS; Network Access's is as entered")
    func login() {
        let remote = BlackmagicConnection(host: "192.0.2.105", useHTTPS: false, username: "ignored", remoteControl: true)
        #expect(remote.user == "BMD_RESTCONTROL_USERNAME" && remote.secure)
        let network = BlackmagicConnection(host: "192.0.2.105", useHTTPS: false, username: "crew")
        #expect(network.user == "crew" && !network.secure)
        #expect(BlackmagicConnection(host: "192.0.2.105").user == nil)
    }

    @Test("A connection saved before Remote Control decodes as Network Access; one with it keeps it")
    func coding() throws {
        let old = try JSONDecoder().decode(BlackmagicConnection.self,
                                           from: Data(#"{"host":"192.0.2.105","useHTTPS":true,"username":"crew"}"#.utf8))
        #expect(!old.remoteControl && old.user == "crew")
        let saved = try JSONEncoder().encode(remote("192.0.2.105"))
        #expect(try JSONDecoder().decode(BlackmagicConnection.self, from: saved).remoteControl)
    }

    @Test("A profile saved before Remote Control still loads; one with it keeps it")
    func profileCoding() throws {
        let old = #"{"id":"6F2C6B0A-6E7B-4E54-8E43-4C4E4B6E3D21","name":"PYXIS","address":"192.0.2.105","cameraType":"blackmagic","color":"red","useAccessAuthentication":false,"useHTTPS":true}"#
        let profile = try JSONDecoder().decode(CameraProfileRecord.self, from: Data(old.utf8))
        #expect(profile.remoteControl == nil && profile.useHTTPS)
        var withIt = profile
        withIt.remoteControl = true
        let decoded = try JSONDecoder().decode(CameraProfileRecord.self, from: JSONEncoder().encode(withIt))
        #expect(decoded.remoteControl == true)
    }

    @MainActor @Test("Save as Profile keeps Remote Control and the remote password, not a user name")
    func saveAsProfile() throws {
        let credentials = InMemoryCredentialStore()
        let store = DashboardStore(cameras: [], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                   startCameras: false, credentials: credentials)
        let camera = store.addCamera(label: "P", color: .blue, host: "192.0.2.105",
                                     connection: .blackmagic(BlackmagicConnection(host: "192.0.2.105", useHTTPS: true,
                                                                                  remoteControl: true)),
                                     password: "remote-pass")
        let profile = try #require(store.saveAsProfile(from: camera.id, name: "PYXIS"))
        #expect(profile.remoteControl == true && profile.username == nil && profile.useAccessAuthentication)
        #expect(credentials.profilePassword(for: profile.id) == "remote-pass")
    }
}
