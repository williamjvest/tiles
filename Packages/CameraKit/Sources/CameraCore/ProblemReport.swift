import Foundation

/// Where problem reports and questions go.
public enum Support {
    public static let email = "william@toldwell.com"
    public static let site = URL(string: "https://tiles.toldwell.com")!
}

/// A problem report, as its sender sees it before it goes: what they say happened, then what helps find the cause. That
/// is the app and the device, each camera with what it is, how Tiles reaches it and its state, and the Activity Log.
/// It never holds a password, token, user name or fingerprint: `init(store:…)` reads none of them.
public struct ProblemReport: Sendable, Equatable {
    public struct Camera: Sendable, Equatable, Identifiable {
        public var id: UUID
        /// Its label on the tiles: "A", "FX3".
        public var label: String
        /// What it is: "Sony FX3 (ILME-FX3)", or "Sony camera" before it has said.
        public var name: String
        /// Its model alone, for the subject line: "FX3".
        public var model: String?
        /// How Tiles reaches it: "Camera Remote, 192.168.1.20", "Blackmagic REST, USB".
        public var link: String
        /// "Connected, 38 ms", "Couldn't connect: The camera didn't answer."
        public var state: String

        public init(id: UUID = UUID(), label: String, name: String, model: String? = nil, link: String, state: String) {
            self.id = id
            self.label = label
            self.name = name
            self.model = model
            self.link = link
            self.state = state
        }
    }

    /// What happened, in the sender's words.
    public var whatHappened: String
    /// "Tiles 1.0 (261116.2349)"
    public var app: String
    /// "iPad16,1, iPadOS 26.1"
    public var device: String
    public var cameras: [Camera]
    /// Settings that change what Tiles does: "Test Mode on".
    public var settings: [String]
    /// What Tiles has done with its cameras since it opened (`ActivityLog`).
    public var log: String

    public init(whatHappened: String, app: String, device: String, cameras: [Camera], settings: [String], log: String) {
        self.whatHappened = whatHappened
        self.app = app
        self.device = device
        self.cameras = cameras
        self.settings = settings
        self.log = log
    }

    public var subject: String {
        let models = cameras.map { $0.model ?? $0.label }
        guard !models.isEmpty else { return "Tiles problem report" }
        let shown = models.prefix(3).joined(separator: ", ") + (models.count > 3 ? " and \(models.count - 3) more" : "")
        return "Tiles problem report: \(shown)"
    }

    public var logLineCount: Int { log.isEmpty ? 0 : log.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// The report without its log, for an email's body; the log goes with it as an attachment.
    public var summary: String {
        heading + "\n\n" + (log.isEmpty ? "The Activity Log is empty." : "The Activity Log is attached (\(lines(logLineCount))).")
    }

    /// The whole report as text: what Copy Report puts on the clipboard.
    public var text: String {
        heading + "\n\nActivity Log:\n" + (log.isEmpty ? "(empty)" : log)
    }

    /// A `mailto:` link, for a device that can't attach the log: the report, with as much of the log's end as fits.
    public func mailto(maxLength: Int = 6000) -> URL? {
        let all = log.isEmpty ? [] : log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept = 0
        var url = mailtoURL(body: heading)
        while kept < all.count {
            let tail = all.suffix(kept + 1)
            let note = tail.count == all.count ? "Activity Log:" : "Activity Log, its last \(lines(tail.count)):"
            guard let next = mailtoURL(body: heading + "\n\n" + note + "\n" + tail.joined(separator: "\n")),
                  next.absoluteString.count <= maxLength else { break }
            url = next
            kept += 1
        }
        return url
    }

    private var heading: String {
        let said = whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [said.isEmpty ? "(Nothing written about what happened.)" : said, "\(app) on \(device)"]
        if !cameras.isEmpty {
            parts.append((["Cameras:"] + cameras.map { "\($0.label): \($0.name), \($0.link). \($0.state)" })
                .joined(separator: "\n"))
        }
        if !settings.isEmpty { parts.append(settings.joined(separator: ". ") + ".") }
        return parts.joined(separator: "\n\n")
    }

    private func mailtoURL(body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Support.email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // `+` survives a query item as itself, and a mail app reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }
}

extension ProblemReport {
    /// The report for what `store` holds now. `app` and `device` come from the app, which knows its bundle and the
    /// device it runs on.
    @MainActor
    public init(store: DashboardStore, whatHappened: String, app: String, device: String, controlAPIOn: Bool = false,
                log: String = ActivityLog.shared.text) {
        let cameras = store.cameras.map { controller in
            Camera(id: controller.id, label: controller.slot.label,
                   name: Self.name(controller),
                   model: (controller.state.model ?? controller.profile?.model).map(CameraState.modelName),
                   link: Self.link(store.savedCamera(controller.id)?.connection, host: controller.slot.host),
                   state: Self.state(controller.state))
        }
        var settings: [String] = []
        if store.testMode { settings.append("Test Mode on") }
        if store.controlsLocked { settings.append("Controls locked") }
        if controlAPIOn { settings.append("Control API on") }
        if !store.haLowNodes.isEmpty {
            settings.append(store.haLowNodes.count == 1 ? "1 HaLow node" : "\(store.haLowNodes.count) HaLow nodes")
        }
        self.init(whatHappened: whatHappened, app: app, device: device, cameras: cameras, settings: settings, log: log)
    }

    @MainActor
    static func name(_ camera: CameraController) -> String {
        let make = (camera.state.make ?? camera.profile?.make)?.label
        guard let model = camera.state.model ?? camera.profile?.model else {
            return make.map { "\($0) camera" } ?? "A camera that hasn't connected yet"
        }
        let name = CameraState.modelName(model)
        let described = name == model ? model : "\(name) (\(model))"
        // A VENICE's or a PYXIS's model name doesn't say who made it.
        guard let make, !described.hasPrefix(make) else { return described }
        return "\(make) \(described)"
    }

    static func link(_ connection: CameraConnection?, host: String) -> String {
        let place = USBCameraAddress.display(host)
        switch connection {
        case .demo: return "demo camera"
        case .sony(let sony): return "Camera Remote (\(sony.usesAccessAuthentication ? "Access Authentication" : "pairing")), \(place)"
        case .venice: return "VENICE Web Remote, \(place)"
        case .arri: return "ARRI Web Remote, \(place)"
        case .blackmagic(let bm):
            return "Blackmagic REST\(bm.useHTTPS ? " (HTTPS)" : "")\(bm.remoteControl ? " with Remote Control" : ""), \(place)"
        case .blackmagicBluetooth: return "Bluetooth"
        case nil: return place.isEmpty ? "no address" : place
        }
    }

    static func state(_ state: CameraState) -> String {
        var text: String
        switch state.connection {
        case .connected: text = "Connected" + (state.latencyMilliseconds.map { ", \($0) ms" } ?? "")
        case .connecting: text = "Connecting"
        case .awaitingApproval: text = "Waiting for approval on the camera"
        case .fingerprintChanged: text = "Stopped: the camera's fingerprint changed"
        case .stale: text = "Reading the camera again"
        case .failed(let reason): text = "Couldn't connect: \(reason)"
        case .disconnected: text = "Not connected"
        }
        if let last = text.last, !".!?".contains(last) { text += "." }
        if let failure = state.recording.failure { text += " REC: \(failure)" }
        return text
    }
}
