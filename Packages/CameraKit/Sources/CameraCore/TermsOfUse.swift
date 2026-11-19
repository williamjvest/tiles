import Foundation

/// Tiles' Terms of Use: the version in force, its text, and whether this device agreed to it.
///
/// Agreed once, with a tap on Agree, before any camera connects: Sony's license requires its warranty and
/// prohibited-use terms to be explained and agreed to before anyone uses the app. Until then a store made with
/// `holdsRealCameras` connects only its demo cameras. Asked again only when `version` goes up.
public enum TermsOfUse {
    /// Bump when the text changes in a way people must agree to again: everyone sees the sheet once more.
    public static let version = 1
    /// When this version was written, as the sheet and Settings → About show it.
    public static let dated = "28 October 2026"

    /// What the sheet puts first, word for word as the terms have it: Sony's license asks for these two to be explained
    /// and agreed to before anyone uses Tiles, and the third is the one that matters on set.
    public static let sonyWarranty = "Once a Sony camera is used or controlled through Tiles, it will be out of Sony's manufacturer warranty, as Sony separately specifies for that camera."
    public static let sonyProhibitedUses = "You agree not to use Tiles, or a Sony camera controlled with it, for weapons, to transport harmful items, or for military activities such as intelligence, surveillance or reconnaissance. Section 4 has them in full."
    public static let checkTheCamera = "Tiles can miss a command, or fail to start or stop a recording. Confirm on the camera anything that matters before and during a take. Tiles comes with no warranty, and Toldwell's liability is limited (sections 5 to 7)."

    static let acceptanceKey = "termsOfUse.accepted"

    /// What this device agreed to, and when.
    public struct Acceptance: Codable, Equatable, Sendable {
        public var version: Int
        public var acceptedAt: Date
    }

    public static func acceptance(in defaults: UserDefaults) -> Acceptance? {
        defaults.data(forKey: acceptanceKey).flatMap { try? JSONDecoder().decode(Acceptance.self, from: $0) }
    }

    /// The version in force has been agreed to. An older version's agreement doesn't count.
    public static func isAccepted(in defaults: UserDefaults) -> Bool {
        (acceptance(in: defaults)?.version ?? 0) >= version
    }

    public static func accept(in defaults: UserDefaults, at date: Date = Date()) {
        let acceptance = Acceptance(version: version, acceptedAt: date)
        if let data = try? JSONEncoder().encode(acceptance) { defaults.set(data, forKey: acceptanceKey) }
    }

    /// The terms, paragraph by paragraph (`**1. Who we are.** …`): Markdown for bold, nothing else.
    public static var paragraphs: [String] {
        resource("TermsOfUse", "md").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Tiles' own license (MIT), as the repo's LICENSE has it.
    public static var license: String { resource("License", "txt") }

    /// Notices for the third-party software Tiles is built with, as the repo's NOTICE has them.
    public static var acknowledgements: String { resource("Acknowledgements", "txt") }

    static func resource(_ name: String, _ ext: String) -> String {
        Bundle.module.url(forResource: name, withExtension: ext)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
