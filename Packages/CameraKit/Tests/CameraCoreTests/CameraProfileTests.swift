import Foundation
import Testing
@testable import CameraCore

// MARK: - Profile CRUD

@MainActor @Test func profileAddEditDeleteAndReorder() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = InMemoryCredentialStore()
    let store = DashboardStore.load(from: defaults, startCameras: false, credentials: credentials)

    let p1 = CameraProfileRecord(name: "FX5 A", address: "198.51.100.101", cameraType: .sony)
    let p2 = CameraProfileRecord(name: "PYXIS B", address: "198.51.100.105", cameraType: .blackmagic)
    store.addProfile(p1)
    store.addProfile(p2)
    #expect(store.profiles.count == 2)
    #expect(store.profiles.map(\.name) == ["FX5 A", "PYXIS B"])

    var edited = p1
    edited.name = "FX5 Renamed"
    store.updateProfile(p1.id, with: edited)
    #expect(store.profiles.first?.name == "FX5 Renamed")

    store.moveProfiles(fromOffsets: IndexSet(integer: 0), toOffset: 2)
    #expect(store.profiles.map(\.name) == ["PYXIS B", "FX5 Renamed"])

    store.removeProfile(p1.id)
    #expect(store.profiles.count == 1)
    #expect(store.profiles[0].id == p2.id)
}

// MARK: - Password stored and removed on delete

@MainActor @Test func profilePasswordStoredAndRemovedOnDelete() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = InMemoryCredentialStore()
    let store = DashboardStore.load(from: defaults, startCameras: false, credentials: credentials)

    let profile = CameraProfileRecord(name: "FX3 C", address: "198.51.100.103", cameraType: .sony,
                                      useAccessAuthentication: true, username: "TW")
    store.addProfile(profile, password: "s3cr3t")
    #expect(credentials.profilePassword(for: profile.id) == "s3cr3t")

    // Password not in the snapshot JSON
    let saved = String(decoding: defaults.data(forKey: "dashboard.v1") ?? Data(), as: UTF8.self)
    #expect(!saved.contains("s3cr3t"))

    store.removeProfile(profile.id)
    #expect(credentials.profilePassword(for: profile.id) == nil)
}

// MARK: - v4 → v5 migration

@MainActor @Test func v4SnapshotMigratesToV5WithNoProfiles() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // Build a real v4 JSON (from the phone-state file structure)
    struct V4Snapshot: Encodable {
        var version = 4
        var cameras: [SavedCamera]
        var pages: [CameraPage]
        var currentPageID: UUID?
    }
    let (cameras, pages) = DashboardStore.demoLineup()
    let v4data = try JSONEncoder().encode(V4Snapshot(cameras: cameras, pages: pages))
    defaults.set(v4data, forKey: DashboardStore.storageKey)

    let store = DashboardStore.load(from: defaults, startCameras: false)
    // Must have loaded the cameras and pages unchanged
    #expect(store.cameras.count == cameras.count)
    #expect(store.pages.count == pages.count)
    // Profiles must be empty — no profiles key was in v4
    #expect(store.profiles.isEmpty)
    // Saving again must produce v5
    store.addProfile(CameraProfileRecord(name: "Test", address: "10.0.0.1", cameraType: .sony))
    let reloaded = DashboardStore.load(from: defaults, startCameras: false)
    #expect(reloaded.profiles.count == 1)
    #expect(reloaded.profiles[0].name == "Test")
}

// MARK: - Adding a camera from a profile

@MainActor @Test func addingCameraFromProfileFillsAllFields() throws {
    let credentials = InMemoryCredentialStore()
    let storeWithCreds = DashboardStore(cameras: [], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                        startCameras: false, credentials: credentials)

    let profile = CameraProfileRecord(
        name: "FX5 A", address: "198.51.100.101", cameraType: .sony,
        letter: "A", color: .red,
        useAccessAuthentication: true, username: "TW",
        useHTTPS: false
    )
    storeWithCreds.addProfile(profile, password: "pw1")

    // Simulate what the Add Camera UI does when the user taps a profile row
    let existingLabels = Set(storeWithCreds.cameras.map(\.slot.label))
    let suggestedLetter = profile.suggestedLetter(usedLabels: existingLabels)  // "A" is free
    #expect(suggestedLetter == "A")

    storeWithCreds.addCamera(
        label: suggestedLetter ?? storeWithCreds.nextFreeLabel(),
        color: profile.color,
        host: profile.address,
        connection: .sony(SonyConnection(username: profile.username)),
        password: credentials.profilePassword(for: profile.id)
    )

    let added = storeWithCreds.cameras.first!
    #expect(added.slot.label == "A")
    #expect(added.slot.host == "198.51.100.101")
    #expect(added.slot.color == .red)
    let saved = storeWithCreds.savedCamera(added.id)
    #expect(saved?.connection.sony?.username == "TW")
    // No fingerprint — saved on first connect, not from the profile
    #expect(saved?.connection.sony?.trustedFingerprint == nil)
}

@MainActor @Test func profileLetterSkippedWhenAlreadyUsed() throws {
    let storeWithCreds = DashboardStore(
        cameras: [SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "x"), demoBody: .fx3)],
        pages: [CameraPage(name: "All", showsAllCameras: true)],
        startCameras: false
    )
    let profile = CameraProfileRecord(name: "FX3", address: "198.51.100.102", cameraType: .sony, letter: "A")
    let suggested = profile.suggestedLetter(usedLabels: Set(storeWithCreds.cameras.map(\.slot.label)))
    #expect(suggested == nil)  // "A" is in use; caller falls back to nextFreeLabel
}

// MARK: - Save as Profile

@MainActor @Test func saveAsProfileCopiesFieldsNotFingerprint() throws {
    let credentials = InMemoryCredentialStore()
    let storeWithCreds = DashboardStore(
        cameras: [], pages: [CameraPage(name: "All", showsAllCameras: true)],
        startCameras: false, credentials: credentials
    )
    let camera = storeWithCreds.addCamera(
        label: "C", color: .yellow, host: "192.0.2.203",
        connection: .sony(SonyConnection(username: "TW", trustedFingerprint: "SHA256:abc")),
        password: "s3cr3t"
    )
    let profile = storeWithCreds.saveAsProfile(from: camera.id, name: "FX3 C")
    let p = try #require(profile)
    #expect(p.name == "FX3 C")
    #expect(p.address == "192.0.2.203")
    #expect(p.cameraType == .sony)
    #expect(p.username == "TW")
    #expect(credentials.profilePassword(for: p.id) == "s3cr3t")
    // Fingerprint must NOT be on the profile
    #expect(storeWithCreds.profiles.count == 1)
    // The profile record has no fingerprint field by design
}

@MainActor @Test func saveAsProfileReturnsNilForDemoCameras() {
    let store = DashboardStore.preview()
    let demoID = store.cameras.first!.id
    let result = store.saveAsProfile(from: demoID, name: "Demo")
    #expect(result == nil)
}

// MARK: - isAdded check

@Test func profileIsAddedReturnsTrueWhenAddressMatches() {
    let profile = CameraProfileRecord(name: "FX5", address: "198.51.100.101", cameraType: .sony)
    #expect(profile.isAdded(in: ["198.51.100.101", "198.51.100.102"]) == true)
    #expect(profile.isAdded(in: ["198.51.100.102"]) == false)
    #expect(profile.isAdded(in: []) == false)
}

@MainActor @Test func turningOffAccessAuthenticationDropsTheProfilePassword() throws {
    let suite = "camerakit.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = InMemoryCredentialStore()
    let store = DashboardStore.load(from: defaults, startCameras: false, credentials: credentials)
    let profile = store.addProfile(CameraProfileRecord(name: "FX3", address: "198.51.100.102", cameraType: .sony,
                                                       username: "admin"), password: "secret")
    #expect(credentials.password(for: profile.id) == "secret")
    var noLogin = profile
    noLogin.useAccessAuthentication = false
    noLogin.username = nil
    store.updateProfile(profile.id, with: noLogin, password: nil)
    #expect(credentials.password(for: profile.id) == nil, "a profile without a login keeps no password")
}
