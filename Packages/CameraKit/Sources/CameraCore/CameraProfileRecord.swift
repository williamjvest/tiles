import Foundation

/// A saved camera configuration the user can add in one tap.
///
/// Profiles are a library; the dashboard's cameras are the active set. Adding a camera from a profile,
/// or removing that camera, never changes the profile. Profiles do not store SSH fingerprints or pinned
/// TLS certificates — a camera added from a profile saves its own on first connect, exactly as now.
public struct CameraProfileRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var cameraType: ProfileCameraType
    /// Single-letter label, e.g. "A". Optional — the editor may leave it blank.
    public var letter: String?
    public var color: SlotColor
    /// A color picked instead of one of the eight (`CameraSlot.customColor`).
    public var customColor: AppearanceSettings.RGB?
    /// Sony: Access Authentication on/off.
    public var useAccessAuthentication: Bool
    /// Sony: Access Authentication user name.
    public var username: String?
    /// Blackmagic: connect over HTTPS.
    public var useHTTPS: Bool
    /// Blackmagic: through the camera's Remote Control, with its remote password (`BlackmagicConnection.remoteControl`).
    /// Nil in a profile saved before there was a choice: Network Access.
    public var remoteControl: Bool?

    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        cameraType: ProfileCameraType,
        letter: String? = nil,
        color: SlotColor = .red,
        customColor: AppearanceSettings.RGB? = nil,
        useAccessAuthentication: Bool = true,
        username: String? = nil,
        useHTTPS: Bool = false,
        remoteControl: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.cameraType = cameraType
        self.letter = letter
        self.color = color
        self.customColor = customColor
        self.useAccessAuthentication = useAccessAuthentication
        self.username = username
        self.useHTTPS = useHTTPS
        self.remoteControl = remoteControl
    }
}

/// Camera vendor for a profile. Demo is not profileable.
public enum ProfileCameraType: String, CaseIterable, Codable, Sendable {
    case sony
    case blackmagic
    case arri

    public var label: String {
        switch self {
        case .sony: "Sony"
        case .blackmagic: "Blackmagic"
        case .arri: "ARRI"
        }
    }
}

// MARK: - Credential store key

extension CredentialStore {
    /// Password for a profile's Access Authentication credential (Sony). Same Keychain service as camera passwords,
    /// keyed by the profile's own ID, so a profile and a camera never share an entry.
    public func profilePassword(for profileID: UUID) -> String? {
        password(for: profileID)
    }

    public func setProfilePassword(_ password: String?, for profileID: UUID) {
        setPassword(password, for: profileID)
    }
}

// MARK: - "Added" check

extension CameraProfileRecord {
    /// True if `address` matches a camera already in `existingHosts`.
    public func isAdded(in existingHosts: Set<String>) -> Bool {
        existingHosts.contains(address)
    }

    /// The letter to pre-fill when adding a camera from this profile.
    /// Returns the profile's letter if it is set and free; nil otherwise.
    public func suggestedLetter(usedLabels: Set<String>) -> String? {
        guard let letter, !letter.isEmpty else { return nil }
        return usedLabels.contains(letter) ? nil : letter
    }
}
