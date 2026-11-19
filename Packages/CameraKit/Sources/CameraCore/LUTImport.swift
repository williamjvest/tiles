import Foundation

/// One LUT slot on the camera, as reported by the camera's own display-string list.
///
/// `index` is the camera's 1-based slot number (User1 = 1 … User16 = 16).
/// `name` is nil when the slot is empty ("(No Import)" in the raw list), non-nil for a named LUT.
public struct LUTSlot: Sendable, Identifiable, Hashable {
    public var index: Int
    public var name: String?

    public var id: Int { index }

    /// "User1", "User2", … regardless of whether the slot holds a LUT.
    public var label: String { "User\(index)" }

    public init(index: Int, name: String?) {
        self.index = index
        self.name = name
    }
}

/// A camera that supports loading LUT files from the app.
///
/// Conformers live in SonyPTP or the mock; DashboardUI holds only this protocol, not `SonyCameraBackend`.
/// All methods are actor-isolated to the backend's own actor, so callers must `await`.
public protocol LUTImportCapable: Actor {
    /// Current User-slot list (1–16). Empty while the camera is disconnected or the body doesn't support import.
    func lutSlots() async throws -> [LUTSlot]

    /// Import `data` (.cube bytes) into `slot` (1–16) with the given display name.
    /// Throws `LUTImportError` on any failure. On success, the backend emits a new state so the LUT
    /// picker refreshes automatically.
    func importLUT(data: Data, name: String, slot: Int) async throws
}

/// Errors the UI shows in plain language.
public enum LUTImportError: Error, LocalizedError, Sendable {
    case notConnected
    case notSupported(String)
    case busy
    case invalidName
    case tooLarge
    case timeout
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:    "Camera is not connected."
        case .notSupported(let r): "This camera doesn't support LUT import (\(r))."
        case .busy:            "Camera is busy. Try again in a moment."
        case .invalidName:     "The display name was rejected by the camera. Remove special characters and try again."
        case .tooLarge:        "The file is too large for this camera."
        case .timeout:         "The camera didn't respond in time."
        case .other(let m):    m
        }
    }
}
