import Foundation

/// A camera as saved on the device. Its password, if any, is in the `CredentialStore`, not here.
public struct SavedCamera: Codable, Hashable, Sendable {
    public var slot: CameraSlot
    public var connection: CameraConnection
    /// What the camera reported the last time it was connected, so its automatic page keeps its shape offline.
    public var lastSeen: CameraProfile?
    /// The app has offered this camera its own page once (FX3 family). A page the user deletes stays deleted.
    public var soloPageOffered = false
    /// Live view quality and frame rate, when chosen; nil leaves them to the link.
    public var liveView: LiveViewSettings?

    public init(slot: CameraSlot, connection: CameraConnection) {
        self.slot = slot
        self.connection = connection
    }

    public init(slot: CameraSlot, demoBody: MockBody) {
        self.init(slot: slot, connection: .demo(demoBody))
    }

    public var demoBody: MockBody? { connection.demoBody }

    private enum CodingKeys: String, CodingKey { case slot, connection, demoBody, lastSeen, soloPageOffered, liveView }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(CameraSlot.self, forKey: .slot)
        if let connection = try container.decodeIfPresent(CameraConnection.self, forKey: .connection) {
            self.connection = connection
        } else {
            // Saved before connections existed: every camera was a demo.
            connection = .demo(try container.decodeIfPresent(MockBody.self, forKey: .demoBody) ?? .fx3)
        }
        lastSeen = try? container.decodeIfPresent(CameraProfile.self, forKey: .lastSeen)
        soloPageOffered = (try? container.decodeIfPresent(Bool.self, forKey: .soloPageOffered)) ?? false
        liveView = try? container.decodeIfPresent(LiveViewSettings.self, forKey: .liveView)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slot, forKey: .slot)
        try container.encode(connection, forKey: .connection)
        try container.encodeIfPresent(lastSeen, forKey: .lastSeen)
        if soloPageOffered { try container.encode(true, forKey: .soloPageOffered) }
        try container.encodeIfPresent(liveView, forKey: .liveView)
    }
}

/// Builds the backend for a saved camera. The app supplies one that knows Sony; the default here only
/// does demo cameras.
public typealias BackendFactory = @MainActor (SavedCamera, _ password: String?) -> any CameraBackend

/// A tab of cameras. Pages are how one camera vs several works: make a page for "A" alone, one for
/// "A+B", one for everything, and flip between them.
public struct CameraPage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Cameras on an automatic page. A customized page takes its cameras from its tiles instead.
    public var cameraIDs: [UUID]
    /// Shows every camera, including ones added later.
    public var showsAllCameras: Bool
    /// nil = automatic (built-in arrangement for whatever cameras are on the page). Set once the page has
    /// been customized in edit mode.
    public var layout: PageLayout?
    /// Controls that move together across every camera on this page (link groups). Optional so
    /// pages saved before linking existed still decode.
    public var linkedControls: Set<LinkKind>?
    /// Master switch for linking on this page. Off by default: cameras only follow each other while it's on.
    public var linkingOn: Bool?
    /// iPhone arrangements, one per camera (2 columns), made by editing on a phone. A camera without one shows
    /// its automatic column, or the page's customized layout re-flowed. Separate from `layout` because a phone
    /// shows one camera at a time in two columns, so iPad/Mac positions don't carry over.
    public var phoneLayouts: [UUID: PageLayout]?
    /// The page scrolls rather than shrink its tiles to fit the screen: rows keep the height its automatic layout
    /// gets, so tiles can keep being added below. Optional so pages saved before it still decode (nil = fits).
    public var scrolls: Bool?

    /// Which controls link when linking is on. Defaults to all four (WB, frame rate, shutter, record).
    public var links: Set<LinkKind> { linkedControls ?? Set(LinkKind.allCases) }
    public var isLinking: Bool { linkingOn ?? false }
    public var isScrolling: Bool { scrolls ?? false }

    public init(id: UUID = UUID(), name: String, cameraIDs: [UUID] = [], showsAllCameras: Bool = false, layout: PageLayout? = nil) {
        self.id = id
        self.name = name
        self.cameraIDs = cameraIDs
        self.showsAllCameras = showsAllCameras
        self.layout = layout
    }
}

/// Which arrangement an edit applies to: the page's own layout (iPad, Mac) or one camera's iPhone layout.
public enum LayoutTarget: Hashable, Sendable {
    case page
    case phone(UUID)
}
