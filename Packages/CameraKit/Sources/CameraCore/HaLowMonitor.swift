import Foundation
import os

// Read-only link stats from the OpenWrt HaLow nodes around the device (OpenMANET, or the Morse Micro firmware Heltec
// ships), via rpcd's ubus JSON-RPC over HTTP (uhttpd-mod-ubus), and the nodes themselves found through Bonjour, the
// gateway and OpenMANET's own API. See docs/halow-monitoring.md.
//
// rpcd iwinfo.c (github.com/openwrt/rpcd): assoclist station fields include signal, noise, rate and mcs;
//   `rate` is kbit/s as iwinfo_cli.c shows; `mcs` only for HT/VHT/HE/EHT rates.
// uhttpd ubus.c (github.com/openwrt/uhttpd): JSON arrays are batches (uh_ubus_init_batch); a call
//   the session may not make, an expired session included, answers error -32002 "Access denied".

// MARK: - Model

/// Link stats from one HaLow node: its strongest HaLow peer, as `iwinfo assoclist` reports it.
public struct HaLowNodeStats: Sendable, Equatable {
    public var address: String
    /// From system.board, read once when the node is first reached.
    public var hostname: String
    /// The peer's signal, dBm. Nil when the node has no HaLow peer: the link is down.
    public var signalDBm: Int?
    /// Noise floor, dBm.
    public var noiseDBm: Int?
    public var snrDB: Int? {
        guard let s = signalDBm, let n = noiseDBm else { return nil }
        return s - n
    }
    /// TX PHY rate to the peer, kbit/s.
    public var phyRateKbps: Int?
    /// TX MCS. rpcd reports it only for HT/VHT/HE/EHT rates, so it may be absent on HaLow (S1G).
    public var mcsIndex: Int?
    /// Width of the TX rate's channel, MHz.
    public var channelWidthMHz: Int?
    /// Share of TX attempts since the previous poll that were retries (0–1). Nil until two polls with traffic.
    public var txRetryRatio: Double?
    /// Node battery %. Nothing reads one yet (no build we've seen exposes it over ubus); the tile shows it if set.
    public var batteryPercent: Int?
    public var updatedAt: Date

    public init(address: String, hostname: String = "", signalDBm: Int? = nil, noiseDBm: Int? = nil,
                phyRateKbps: Int? = nil, mcsIndex: Int? = nil, channelWidthMHz: Int? = nil,
                txRetryRatio: Double? = nil, batteryPercent: Int? = nil, updatedAt: Date = Date()) {
        self.address = address
        self.hostname = hostname
        self.signalDBm = signalDBm
        self.noiseDBm = noiseDBm
        self.phyRateKbps = phyRateKbps
        self.mcsIndex = mcsIndex
        self.channelWidthMHz = channelWidthMHz
        self.txRetryRatio = txRetryRatio
        self.batteryPercent = batteryPercent
        self.updatedAt = updatedAt
    }
}

/// Where polling a node stands.
public enum HaLowNodeState: Sendable, Equatable {
    /// No password saved: nothing is sent to the node.
    case needsPassword
    /// The node refused the password at login. Not retried until the password changes.
    case loginFailed
    /// The login worked, but the node's rpcd won't let the account read its radios.
    case accessDenied
    /// It answered, but isn't a HaLow node: not rpcd, or no HaLow radio found.
    case notHaLow
    /// No answer: off, out of range, or not on this network.
    case unreachable
    case polling

    public var label: String {
        switch self {
        case .needsPassword: "Needs password"
        case .loginFailed: "Login failed"
        case .accessDenied: "Access denied"
        case .notHaLow: "Not a HaLow node"
        case .unreachable: "No answer"
        case .polling: "Connected"
        }
    }
}

/// One node, as the tile, the link meter and Settings show it.
public struct HaLowNode: Sendable, Equatable, Identifiable {
    public var address: String
    /// Its hostname once it's answered; before that, what Bonjour or the mesh called it, else its address.
    public var name: String
    /// Added by hand in Settings, rather than found.
    public var isManual: Bool
    /// This device is on it: on its Wi-Fi, holding a lease from it, or routing through it.
    public var isLocal: Bool
    /// Nil: found, not polled yet.
    public var state: HaLowNodeState?
    public var stats: HaLowNodeStats?
    public var id: String { address }

    public init(address: String, name: String, isManual: Bool = false, isLocal: Bool = false,
                state: HaLowNodeState? = nil, stats: HaLowNodeStats? = nil) {
        self.address = address
        self.name = name
        self.isManual = isManual
        self.isLocal = isLocal
        self.state = state
        self.stats = stats
    }
}

// MARK: - Settings

public enum HaLowDisplayMode: String, Codable, Sendable, CaseIterable {
    /// HaLow shows only while a node answers.
    case auto
    /// Nodes added by hand, and nodes that have answered, always show with their state, so a dropped link reads as
    /// down rather than vanishing.
    case on
    /// Nothing is polled or looked for.
    case off
}

public struct HaLowSettings: Codable, Sendable, Equatable {
    public var displayMode: HaLowDisplayMode
    /// Nodes added by hand, for a mesh the app can't find by itself. Saved as `nodeAddresses`, the key saved setups use.
    public var manualAddresses: [String]
    /// The login on every node (rpcd, and OpenMANET's own API).
    public var username: String

    public init(displayMode: HaLowDisplayMode = .auto, manualAddresses: [String] = [], username: String = "root") {
        self.displayMode = displayMode
        self.manualAddresses = manualAddresses
        self.username = username
    }

    enum CodingKeys: String, CodingKey {
        case displayMode
        case manualAddresses = "nodeAddresses"
        case username
    }
}

/// The nodes' password in the app's credential store: one for every node (version nibble 5, so never a camera's v4
/// UUID).
public let haLowPasswordID = UUID(uuidString: "4A4C4F57-0000-5000-8000-000000000001")!

/// A per-node password ID, as setups saved before `haLowPasswordID` keyed them; `migrateLegacyPasswords` reads them.
func legacyHaLowPasswordID(for address: String) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    for (i, byte) in address.utf8.enumerated() { bytes[i % 16] ^= byte }
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

extension HaLowSettings {
    /// Moves a saved setup's per-node passwords to the one password: the first becomes it, and the copies go.
    public func migrateLegacyPasswords(in credentials: any CredentialStore) {
        let legacy = manualAddresses.map(legacyHaLowPasswordID(for:)).filter { credentials.password(for: $0) != nil }
        guard !legacy.isEmpty else { return }
        if credentials.password(for: haLowPasswordID) == nil,
           let password = legacy.lazy.compactMap({ credentials.password(for: $0) }).first(where: { !$0.isEmpty }) {
            credentials.setPassword(password, for: haLowPasswordID)
        }
        guard credentials.password(for: haLowPasswordID) != nil else { return }  // the Keychain didn't take it: keep them
        for id in legacy { credentials.setPassword(nil, for: id) }
    }
}

public protocol HaLowHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HaLowHTTPTransport {}

// MARK: - Monitor

/// Finds the HaLow nodes around the device and polls them, read-only.
///
/// Finding: a short Bonjour browse for web servers (`_http._tcp`), plus the default gateway, gives candidates; each
/// gets a password-free check that it's a HaLow node before the password goes to it (`identify`): OpenMANET's web API
/// (`GET :8080/auth/check`), or a login page naming a Morse Micro HaLow node (`GET /cgi-bin/luci/`, as the firmware
/// Heltec ships and OpenMANET both serve). Then any answering OpenMANET node lists the rest of the mesh
/// (`NodeService/ListNodes`), so finding one finds them all; Heltec's firmware keeps no such list, so its nodes are
/// found one by one. Nodes added by hand are polled as they are. Nothing is looked for or sent without a password,
/// except while Settings asks (`findNodes`): then it browses and checks, password-free, to list what's there.
///
/// Polling, per node, once: log in, then one batch finds the HaLow radio by its band (a node also runs a 2.4 GHz AP;
/// "the first wlan" would be the phone's own Wi-Fi link), the hostname, and whether this device holds a lease there.
/// After that every poll is ONE request: `iwinfo assoclist` on that radio, plus, on a node with an AP, whether this
/// device is on it. The node this device is on is polled every `localPollInterval` (local Wi-Fi or cable); any other
/// node across the HaLow link every `remotePollInterval`. A found node that stops answering backs off to 15 min.
/// Nothing is polled in the background or when Off.
public actor HaLowMonitor {
    public private(set) var settings: HaLowSettings
    public private(set) var isForeground = true

    private let credentialStore: any CredentialStore
    private let transport: any HaLowHTTPTransport
    private let browser: (any HaLowNodeBrowser)?
    private let localPollInterval: TimeInterval
    private let remotePollInterval: TimeInterval
    private let requestTimeout: TimeInterval
    private let browseSeconds: Double
    private let gateway: @Sendable () -> String?
    private let localAddresses: @Sendable () -> Set<String>
    /// How often an answering node is asked for the rest of the mesh.
    static let meshListInterval: TimeInterval = 300
    /// How often to browse again while no node answers.
    static let rebrowseInterval: TimeInterval = 120

    private var pollTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var onChange: (@Sendable ([HaLowNode]) -> Void)?
    /// Bumped by a settings change: a reply to a request sent before it is dropped.
    private var generation = 0

    private struct Found {
        var name: String?
        /// Listed by a node of the mesh, rather than found on the local network.
        var viaMesh: Bool
        var failures = 0
        var retryAt: Date?
    }
    private struct Radio {
        var device: String
        /// The HaLow interface's MAC: tells one node at two addresses apart from two nodes.
        var mac: String?
        /// The node's Wi-Fi access points, where this device may be a station.
        var accessPoints: [String]
    }

    private var found: [String: Found] = [:]
    private struct Candidate {
        var name: String?
        var viaMesh: Bool
    }
    /// Waiting for the check: found on the network, or listed by a node of the mesh.
    private var candidates: [String: Candidate] = [:]
    /// Checked this session and answered: true, a HaLow node. A host that didn't answer isn't recorded.
    private var checked: [String: Bool] = [:]
    /// Another address of a node already polled under one: never polled.
    private var aliases: Set<String> = []
    private var stats: [String: HaLowNodeStats] = [:]
    private var states: [String: HaLowNodeState] = [:]
    private var answered: Set<String> = []
    private var lastBrowse: Date?
    private var lastMeshList: Date?
    /// This device's addresses at the last pass: a change means its leases (and so its node) may have moved.
    private var lastLocalAddresses: Set<String> = []
    /// Nodes whose leases the next poll reads again, to see whether this device's lease moved.
    private var leasesDue: Set<String> = []

    private var tokens: [String: String] = [:]
    private var logins: [String: Task<String, Error>] = [:]
    private var meshTokens: [String: String] = [:]
    private var radios: [String: Radio] = [:]
    private var hostnames: [String: String] = [:]
    private var counters: [String: (mac: String, packets: Int, retries: Int)] = [:]
    private var lastPolled: [String: Date] = [:]
    /// The password a node refused; it isn't tried again until the saved one differs.
    private var refusedPasswords: [String: String] = [:]

    /// This device's MACs, as the nodes' DHCP leases record them.
    private var ourMACs: Set<String> = []
    /// Nodes holding one of this device's leases.
    private var leaseHolders: Set<String> = []
    /// Nodes whose access point has this device as a station.
    private var attached: Set<String> = []

    public init(settings: HaLowSettings = HaLowSettings(),
                credentialStore: any CredentialStore,
                localPollInterval: TimeInterval = 10,
                remotePollInterval: TimeInterval = 60,
                requestTimeout: TimeInterval = 3,
                browseSeconds: Double = 4,
                gateway: @escaping @Sendable () -> String? = { DefaultGateway.ipv4() },
                localAddresses: @escaping @Sendable () -> Set<String> = { LocalAddresses.ipv4() },
                browser: (any HaLowNodeBrowser)? = BonjourNodeBrowser(),
                transport: (any HaLowHTTPTransport)? = nil) {
        self.settings = settings
        self.credentialStore = credentialStore
        self.localPollInterval = localPollInterval
        self.remotePollInterval = remotePollInterval
        self.requestTimeout = requestTimeout
        self.browseSeconds = browseSeconds
        self.gateway = gateway
        self.localAddresses = localAddresses
        self.browser = browser
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = requestTimeout
            config.timeoutIntervalForResource = requestTimeout * 2
            config.waitsForConnectivity = false
            config.httpShouldSetCookies = false
            self.transport = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    // MARK: Control

    /// Called after every pass with the nodes, this device's own first, then by name.
    public func setOnChange(_ handler: @escaping @Sendable ([HaLowNode]) -> Void) {
        onChange = handler
    }

    public func apply(_ newSettings: HaLowSettings) {
        guard newSettings != settings else { return }
        generation += 1
        if newSettings.username != settings.username {
            tokens = [:]
            meshTokens = [:]
            refusedPasswords = [:]
        }
        let dropped = Set(settings.manualAddresses).subtracting(newSettings.manualAddresses)
        settings = newSettings
        for address in dropped where found[address] == nil { forget(address) }
        if newSettings.displayMode == .off {
            for address in Set(states.keys).union(found.keys).union(stats.keys) { forget(address) }
            candidates = [:]
            checked = [:]
            aliases = []
            lastBrowse = nil
            lastMeshList = nil
        }
        restart()
        publish()
    }

    /// The app's scene phase: nothing polls in the background.
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if !foreground { generation += 1 }  // a pass in flight stops, and requests suspension kills don't count
        restart()
    }

    /// The password was saved or changed: look for nodes if that's new, and try it now.
    public func passwordChanged() async {
        refusedPasswords = [:]
        restart()
        await pollPass(force: true)
    }

    /// Poll every node now, instead of waiting for the next pass.
    public func pollNow() async {
        await pollPass(force: true)
    }

    /// Settings asked: browse and check now, password or not, and poll what's found if there's a password.
    public func findNodes() async {
        guard settings.displayMode != .off else { return }
        await browse()
        await pollPass(force: true)
    }

    /// The nodes in display order: this device's own first, then by name.
    public func currentNodes() -> [HaLowNode] {
        let local = localNodes()
        return knownAddresses.filter { address in
            if settings.manualAddresses.contains(address) || answered.contains(address) { return true }
            return [.needsPassword, .loginFailed, .accessDenied].contains(states[address])
        }
        .map { address in
            HaLowNode(address: address, name: hostnames[address] ?? found[address]?.name ?? address,
                      isManual: settings.manualAddresses.contains(address), isLocal: local.contains(address),
                      state: states[address], stats: stats[address])
        }
        .sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.address < b.address
        }
    }

    // MARK: Passes

    private var password: String? {
        credentialStore.password(for: haLowPasswordID).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func restart() {
        pollTask?.cancel()
        pollTask = nil
        browseTask?.cancel()
        browseTask = nil
        guard isForeground, settings.displayMode != .off else { return }
        let hasPassword = password != nil
        guard hasPassword || !settings.manualAddresses.isEmpty || !found.isEmpty else { return }
        let interval = localPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let monitor = self else { return }
                await monitor.pollPass(force: false)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        if hasPassword { startBrowse() }
    }

    private func startBrowse() {
        guard browser != nil else { return }
        browseTask = Task { [weak self] in
            await self?.browse()
            await self?.browseFinished()
            guard !Task.isCancelled else { return }
            await self?.pollPass(force: false)
        }
    }

    private func browseFinished() {
        if !Task.isCancelled { browseTask = nil }
    }

    private func browse() async {
        guard let browser else { return }
        let generation = self.generation
        lastBrowse = Date()
        let hits = await browser.browse(seconds: browseSeconds)
        guard generation == self.generation, settings.displayMode != .off else { return }
        for hit in hits { consider(hit.address, name: hit.name) }
        if let address = gateway() { consider(address, name: nil) }
    }

    private func consider(_ address: String, name: String?, viaMesh: Bool = false) {
        guard !isKnown(address), !aliases.contains(address), checked[address] == nil else { return }
        candidates[address] = Candidate(name: name.flatMap { $0.isEmpty ? nil : $0 }, viaMesh: viaMesh)
    }

    private func isKnown(_ address: String) -> Bool {
        settings.manualAddresses.contains(address) || found[address] != nil
    }

    /// Added by hand, in their order, then found, by address; never an alias.
    private var knownAddresses: [String] {
        (settings.manualAddresses + found.keys.filter { !settings.manualAddresses.contains($0) }.sorted())
            .filter { !aliases.contains($0) }
    }

    /// One pass at a time: the poll loop, `pollNow`, a browse finishing and Settings all come through here.
    func pollPass(force: Bool, now: Date = Date()) async {
        let previous = passTask
        let task = Task { await previous?.value; await self.pass(force: force, now: now) }
        passTask = task
        await task.value
    }

    private func pass(force: Bool, now: Date) async {
        guard isForeground, settings.displayMode != .off else { return }
        let generation = self.generation
        let password = self.password
        if password != nil, let address = gateway() { consider(address, name: nil) }
        let mine = localAddresses()
        if mine != lastLocalAddresses {  // another network, or another node's lease: learn who this device is again
            lastLocalAddresses = mine
            ourMACs = []
            attached = []
            leasesDue = Set(knownAddresses)
        }
        guard await checkCandidates(generation: generation) else { return }
        await pollDue(force: force, now: now, password: password, generation: generation)
        guard generation == self.generation else { return }
        if let password, await listMesh(now: now, password: password, generation: generation) {
            guard await checkCandidates(generation: generation) else { return }
            await pollDue(force: false, onlyNew: true, now: now, password: password, generation: generation)
        }
        if password != nil, !states.values.contains(.polling), browseTask == nil,
           lastBrowse.map({ now.timeIntervalSince($0) >= Self.rebrowseInterval }) ?? true {
            startBrowse()
        }
        publish()
    }

    /// Checks every candidate side by side; those that answer as HaLow nodes are found. False: the settings changed
    /// meanwhile.
    private func checkCandidates(generation: Int) async -> Bool {
        let pending = candidates
        candidates = [:]
        guard !pending.isEmpty else { return true }
        let transport = self.transport, timeout = requestTimeout
        let checks = await withTaskGroup(of: (String, NodeCheck).self) { group in
            for address in pending.keys {
                group.addTask { (address, await Self.identify(address, transport: transport, timeout: timeout)) }
            }
            var results: [String: NodeCheck] = [:]
            for await (address, check) in group { results[address] = check }
            return results
        }
        guard generation == self.generation else { return false }
        for (address, check) in checks {
            switch check {
            case .node:
                checked[address] = true
                if !isKnown(address), let candidate = pending[address] {
                    found[address] = Found(name: candidate.name, viaMesh: candidate.viaMesh)
                    leasesDue.remove(address)  // its first poll reads them anyway
                }
            case .notANode:
                checked[address] = false
            case .noAnswer:
                break  // worth asking again later
            }
        }
        return true
    }

    private func pollDue(force: Bool, onlyNew: Bool = false, now: Date, password: String?, generation: Int) async {
        let local = localNodes()
        for address in knownAddresses {
            guard !Task.isCancelled, generation == self.generation else { return }
            if onlyNew, lastPolled[address] != nil { continue }
            if let retryAt = found[address]?.retryAt, now < retryAt { continue }
            if !force, !local.contains(address), let last = lastPolled[address],
               now.timeIntervalSince(last) < remotePollInterval { continue }
            lastPolled[address] = now
            await poll(address, password: password, now: now, generation: generation)
        }
    }

    private func poll(_ address: String, password: String?, now: Date, generation: Int) async {
        guard let password else {
            stats[address] = nil
            states[address] = .needsPassword
            return
        }
        if refusedPasswords[address] == password { return }
        do {
            let result = try await readStats(address, password: password)
            guard generation == self.generation, isKnown(address) else { return }
            stats[address] = result
            states[address] = .polling
            answered.insert(address)
            refusedPasswords[address] = nil
            found[address]?.failures = 0
            found[address]?.retryAt = nil
            dropDuplicate(of: address)
        } catch {
            guard generation == self.generation, isKnown(address), !Task.isCancelled else { return }
            stats[address] = nil
            switch error as? HaLowError {
            case .loginRefused:
                tokens[address] = nil
                refusedPasswords[address] = password
                states[address] = .loginFailed
            case .accessDenied:
                tokens[address] = nil
                states[address] = .accessDenied
            case .notHaLow:
                radios[address] = nil
                if settings.manualAddresses.contains(address) {
                    states[address] = .notHaLow
                } else {
                    forget(address)  // a box that passed the check but has no HaLow radio isn't one of the nodes
                    checked[address] = false
                }
            case nil:
                states[address] = .unreachable
                if var node = found[address] {
                    node.failures += 1
                    node.retryAt = now.addingTimeInterval(min(remotePollInterval * pow(2, Double(node.failures - 1)), 900))
                    found[address] = node
                }
            }
        }
    }

    /// The same node found twice (its LAN address on Bonjour, its mesh address from the mesh's list): keep one, by
    /// its HaLow MAC. Added by hand beats found, and the mesh's address beats the LAN's.
    private func dropDuplicate(of address: String) {
        guard let mac = radios[address]?.mac,
              let other = radios.first(where: { $0.key != address && $0.value.mac == mac && isKnown($0.key) })?.key
        else { return }
        func rank(_ a: String) -> Int {
            settings.manualAddresses.contains(a) ? 2 : (found[a]?.viaMesh == true ? 1 : 0)
        }
        let loser = rank(address) == rank(other) ? (answered.contains(other) ? address : other)
            : (rank(address) < rank(other) ? address : other)
        guard !settings.manualAddresses.contains(loser) else { return }
        forget(loser)
        aliases.insert(loser)
    }

    /// The node(s) this device is on: whose AP has it as a station; else whose DHCP lease it holds; else its gateway.
    private func localNodes() -> Set<String> {
        if !attached.isEmpty { return attached }
        if !leaseHolders.isEmpty { return leaseHolders }
        if let address = gateway(), isKnown(address) { return [address] }
        return []
    }

    // MARK: Reading a node

    private func readStats(_ address: String, password: String) async throws -> HaLowNodeStats {
        if radios[address] == nil { try await discover(address, password: password) }
        guard let radio = radios[address] else { throw HaLowError.notHaLow }
        var calls = [UbusCall("iwinfo", "assoclist", ["device": radio.device])]
        let readsLeases = leasesDue.remove(address) != nil
        if readsLeases { calls.append(UbusCall("luci-rpc", "getDHCPLeases", ["family": 4])) }
        let stationChecks = calls.count
        let macs = ourMACs.sorted()
        for accessPoint in radio.accessPoints {
            for mac in macs { calls.append(UbusCall("iwinfo", "assoclist", ["device": accessPoint, "mac": mac])) }
        }
        let replies = try await call(address, password: password, calls)
        if replies[0].accessDenied { throw HaLowError.accessDenied }
        guard replies[0].code == 0, let stations = replies[0].object?["results"] as? [[String: Any]] else {
            radios[address] = nil  // the interface went away (radio restarted, renamed): find it again next poll
            throw HaLowError.notHaLow
        }
        if readsLeases { noteLeases(replies[1].object?["dhcp_leases"] as? [[String: Any]], on: address) }
        if calls.count > stationChecks {
            // With a `mac`, rpcd answers that one station, or UBUS_STATUS_NOT_FOUND when it isn't associated.
            if replies[stationChecks...].contains(where: { $0.code == 0 }) { attached.insert(address) } else { attached.remove(address) }
        }
        var result = HaLowNodeStats(address: address, hostname: hostnames[address] ?? address)
        // A mesh node can hear several peers; the strongest is the link in use.
        guard let peer = stations.max(by: { (Self.int($0["signal"]) ?? -999) < (Self.int($1["signal"]) ?? -999) })
        else {
            counters[address] = nil
            return result  // no HaLow peer: the link is down
        }
        result.signalDBm = Self.int(peer["signal"])
        result.noiseDBm = Self.int(peer["noise"])
        if let tx = peer["tx"] as? [String: Any] {
            result.phyRateKbps = Self.int(tx["rate"])
            result.mcsIndex = Self.int(tx["mcs"])
            result.channelWidthMHz = Self.int(tx["mhz"]).flatMap { $0 > 0 ? $0 : nil }
            let mac = peer["mac"] as? String ?? ""
            if let packets = Self.int(tx["packets"]), let retries = Self.int(tx["retries"]) {
                if let last = counters[address], last.mac == mac, packets >= last.packets, retries >= last.retries,
                   packets - last.packets + retries - last.retries > 0 {
                    let newRetries = Double(retries - last.retries)
                    result.txRetryRatio = newRetries / (Double(packets - last.packets) + newRetries)
                }
                counters[address] = (mac, packets, retries)
            }
        }
        return result
    }

    /// Once per node, one batch: the hostname (`system board`), the radios (`luci-rpc getWirelessDevices`, which
    /// carries each interface's iwinfo) and its IPv4 DHCP leases (to see whether this device holds one). All three are
    /// in OpenWrt's stock LuCI ACLs; a node that won't answer the radios to this account is Access denied.
    private func discover(_ address: String, password: String) async throws {
        let replies = try await call(address, password: password, [
            UbusCall("system", "board"),
            UbusCall("luci-rpc", "getWirelessDevices"),
            UbusCall("luci-rpc", "getDHCPLeases", ["family": 4]),
        ])
        hostnames[address] = (replies[0].object?["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        noteLeases(replies[2].object?["dhcp_leases"] as? [[String: Any]], on: address)
        guard replies[1].code == 0, let devices = replies[1].object else { throw HaLowError.accessDenied }
        guard let radio = Self.radio(wirelessDevices: devices) else { throw HaLowError.notHaLow }
        radios[address] = radio
    }

    private func noteLeases(_ leases: [[String: Any]]?, on address: String) {
        guard let leases else { return }
        let mine = localAddresses()
        let held = leases.filter { ($0["ipaddr"] as? String).map(mine.contains) == true }
        ourMACs.formUnion(held.compactMap { ($0["macaddr"] as? String)?.lowercased() })
        if held.isEmpty { leaseHolders.remove(address) } else { leaseHolders.insert(address) }
    }

    private static func radio(wirelessDevices: [String: Any]) -> Radio? {
        var haLow: Radio?
        var accessPoints: [String] = []
        for case let device as [String: Any] in wirelessDevices.values {
            // The radio's own settings say sub-GHz wherever iwinfo doesn't: band s1g, hwmode 11ah, as both OpenMANET
            // and Heltec's firmware set the morse radio.
            let config = device["config"] as? [String: Any]
            let s1g = config?["band"] as? String == "s1g" || config?["hwmode"] as? String == "11ah"
            for case let interface as [String: Any] in device["interfaces"] as? [Any] ?? [] {
                guard let name = interface["ifname"] as? String else { continue }
                let iwinfo = interface["iwinfo"] as? [String: Any]
                // On the s1g radio, an interface iwinfo reports: one that's down has no iwinfo, and no stations.
                if haLow == nil, s1g && iwinfo != nil || isHaLow(iwinfo) {
                    // A mesh point's or AP's BSSID is its own MAC; a station's is its AP's, shared, so not an identity.
                    let own = ["Mesh Point", "Master"].contains(iwinfo?["mode"] as? String ?? "")
                    haLow = Radio(device: name, mac: own ? (iwinfo?["bssid"] as? String)?.lowercased() : nil,
                                  accessPoints: [])
                } else if (interface["config"] as? [String: Any])?["mode"] as? String == "ap"
                            || iwinfo?["mode"] as? String == "Master" {
                    accessPoints.append(name)
                }
            }
        }
        haLow?.accessPoints = accessPoints.sorted()
        return haLow
    }

    // MARK: Telling a node without a password

    /// Which check a node passed.
    enum NodeFirmware: Sendable, Equatable {
        /// OpenMANET's openmanetd answered `/auth/check`: it can list the rest of the mesh.
        case openMANET
        /// Its login page is a Morse Micro HaLow node's: the firmware Heltec ships (or OpenMANET, its openmanetd away).
        case morse
    }

    enum NodeCheck: Sendable, Equatable {
        case node(NodeFirmware)
        /// Its web server answered, as something else: a router, a printer. It never gets the password.
        case notANode
        /// Nothing conclusive answered: worth asking again later.
        case noAnswer
    }

    /// The password-free check before the password goes anywhere: OpenMANET's web API and the login page, side by
    /// side (they're different ports, and a host that drops both shouldn't hold up the pass for two timeouts). Only a
    /// login page that answered without the marker makes a host "not a node" for the session; silence never does.
    static func identify(_ address: String, transport: any HaLowHTTPTransport, timeout: TimeInterval) async -> NodeCheck {
        await withTaskGroup(of: (NodeFirmware, Bool?).self) { group in
            group.addTask { (.openMANET, await isOpenMANET(address, transport: transport, timeout: timeout)) }
            // LuCI draws its login page through Lua on the node's MIPS core: more time than an API answer.
            group.addTask { (.morse, await isMorseFirmware(address, transport: transport, timeout: timeout * 2)) }
            var morse: Bool?
            for await (firmware, answer) in group {
                if firmware == .openMANET {
                    if answer == true {
                        group.cancelAll()
                        return .node(.openMANET)
                    }
                } else {
                    morse = answer
                }
            }
            switch morse {
            case true?: return .node(.morse)
            case false?:
                logger.info("\(address, privacy: .public) answered on port 80, but not as a HaLow node: never sent the password")
                return .notANode
            case nil: return .noAnswer
            }
        }
    }

    /// The firmware Heltec ships (Morse Micro's OpenWrt 23.05, LuCI theme morseargon), and OpenMANET's theme forked from
    /// it, head every page with `<meta name="application-name" content="<hostname> - MM HaLow Device">`, the login page
    /// LuCI serves without a login included. Nothing secret is sent. Nil: nothing answered.
    static func isMorseFirmware(_ address: String, transport: any HaLowHTTPTransport, timeout: TimeInterval) async -> Bool? {
        guard let url = URL(string: "http://\(address)/cgi-bin/luci/") else { return false }
        guard let (data, response) = try? await transport.data(for: URLRequest(url: url, timeoutInterval: timeout)),
              response is HTTPURLResponse else { return nil }
        let page = String(decoding: data, as: UTF8.self)
        return page.range(of: #"<meta name="application-name" content="[^"<>]* - MM HaLow Device">"#,
                          options: .regularExpression) != nil
    }

    private static let logger = Logger(subsystem: "com.toldwell.tiles", category: "HaLow")

    /// OpenMANET's web API (openmanetd, port 8080) answers `/auth/check` without a login. Nothing secret is sent.
    /// Nil: nothing answered, so it's worth asking again later.
    static func isOpenMANET(_ address: String, transport: any HaLowHTTPTransport, timeout: TimeInterval) async -> Bool? {
        guard let (status, data) = try? await openmanet(address, "/auth/check", body: nil, token: nil,
                                                        transport: transport, timeout: timeout) else { return nil }
        guard status == 200, let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return reply["authEnabled"] is Bool
    }

    /// Asks an answering node for the mesh's other nodes, which are checked like any candidate. True when it names
    /// any not known yet.
    private func listMesh(now: Date, password: String, generation: Int) async -> Bool {
        guard lastMeshList.map({ now.timeIntervalSince($0) >= Self.meshListInterval }) ?? true else { return false }
        let local = localNodes()
        // Every answering node is asked, Heltec's firmware too: it has no list (nothing listens on 8080, so that's one
        // refused connection), but an OpenMANET node whose openmanetd was restarting at its check looks the same.
        let answering = knownAddresses
            .filter { states[$0] == .polling }
            .sorted { local.contains($0) && !local.contains($1) }
        guard !answering.isEmpty else { return false }
        lastMeshList = now
        leasesDue.formUnion(knownAddresses)
        for address in answering {
            guard let listed = await meshNodes(address, password: password) else { continue }
            guard generation == self.generation else { return false }
            for node in listed { consider(node.address, name: node.name, viaMesh: true) }
            return !candidates.isEmpty
        }
        return false
    }

    /// `openmanet.service.v1.NodeService/ListNodes`: every other node, with its hostname and address, including ones
    /// that have gone quiet. Nil when there's no OpenMANET API there, or it won't log in.
    private func meshNodes(_ address: String, password: String) async -> [(address: String, name: String?)]? {
        for _ in 0..<2 {
            let token: String
            if let saved = meshTokens[address] {
                token = saved
            } else {
                let login = try? JSONSerialization.data(withJSONObject: ["username": settings.username, "password": password])
                guard let (status, data) = try? await openmanet(address, "/auth/login", body: login, token: nil),
                      status == 200,
                      let new = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["token"] as? String
                else { return nil }
                meshTokens[address] = new
                token = new
            }
            guard let (status, data) = try? await openmanet(
                address, "/rpc/openmanet.service.v1.NodeService/ListNodes", body: Data("{}".utf8), token: token)
            else { return nil }
            if status == 401 {
                meshTokens[address] = nil
                continue
            }
            guard status == 200, let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            let nodes = reply["nodes"] as? [[String: Any]] ?? []
            return nodes.compactMap { node in
                guard let ip = node["ipaddr"] as? String, MeshDeviceList.isIPv4(ip) else { return nil }
                return (ip, (node["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        return nil
    }

    private func openmanet(_ address: String, _ path: String, body: Data?, token: String?) async throws -> (Int, Data) {
        try await Self.openmanet(address, path, body: body, token: token, transport: transport, timeout: requestTimeout)
    }

    private static func openmanet(_ address: String, _ path: String, body: Data?, token: String?,
                                  transport: any HaLowHTTPTransport, timeout: TimeInterval) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(address):8080\(path)") else { throw HaLowError.notHaLow }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        }
        if let token { request.setValue("session=\(token)", forHTTPHeaderField: "Cookie") }
        let (data, response) = try await transport.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: ubus

    private struct UbusCall {
        let object: String
        let method: String
        let args: [String: Any]
        init(_ object: String, _ method: String, _ args: [String: Any] = [:]) {
            self.object = object
            self.method = method
            self.args = args
        }
    }

    private struct UbusReply {
        var code: Int?
        var object: [String: Any]?
        /// ACL denied (result code 6 or -32002 JSON-RPC error): the account's rpcd ACL won't allow this call.
        var accessDenied = false
    }

    /// Sends `calls` as one batch under the node's session, logging in when there's none. A session that has expired
    /// makes every call answer -32002, so a batch denied throughout on a saved session logs in once more and resends;
    /// a valid session the ACL restricts answers a mix, which comes back marked.
    private func call(_ address: String, password: String, _ calls: [UbusCall]) async throws -> [UbusReply] {
        let saved = tokens[address]
        var token = try await session(address, password: password)
        var replies = try await batch(address, token: token, calls)
        if saved != nil, !replies.isEmpty, replies.allSatisfy(\.accessDenied) {
            if tokens[address] == token { tokens[address] = nil }
            token = try await session(address, password: password)
            replies = try await batch(address, token: token, calls)
        }
        return replies
    }

    /// The node's session, logging in when there's none: one login at a time per node, however many calls want one.
    private func session(_ address: String, password: String) async throws -> String {
        if let token = tokens[address] { return token }
        if let pending = logins[address] { return try await pending.value }
        let username = settings.username
        let generation = self.generation
        let login = Task { try await self.login(address, username: username, password: password) }
        logins[address] = login
        defer { logins[address] = nil }
        let token = try await login.value
        if generation == self.generation { tokens[address] = token }
        return token
    }

    private func batch(_ address: String, token: String, _ calls: [UbusCall]) async throws -> [UbusReply] {
        let body: [[String: Any]] = calls.enumerated().map { index, call in
            ["jsonrpc": "2.0", "id": index, "method": "call", "params": [token, call.object, call.method, call.args]]
        }
        let data = try await post(address, body)
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw HaLowError.notHaLow
        }
        var replies = Array(repeating: UbusReply(), count: calls.count)
        for item in items {
            guard let id = Self.int(item["id"]), replies.indices.contains(id) else { continue }
            if let error = item["error"] as? [String: Any] {
                replies[id].accessDenied = Self.int(error["code"]) == -32002
            } else if let result = item["result"] as? [Any] {
                replies[id].code = Self.int(result.first)
                replies[id].object = result.dropFirst().first as? [String: Any]
                if replies[id].code == 6 { replies[id].accessDenied = true }  // UBUS_STATUS_PERMISSION_DENIED
            }
        }
        return replies
    }

    private func login(_ address: String, username: String, password: String) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 0, "method": "call",
            "params": ["00000000000000000000000000000000", "session", "login",
                       ["username": username, "password": password]],
        ]
        let data = try await post(address, body)
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = reply["result"] as? [Any], let code = Self.int(result.first) else {
            throw HaLowError.notHaLow  // an HTTP server, but not rpcd
        }
        guard code == 0, let token = (result.dropFirst().first as? [String: Any])?["ubus_rpc_session"] as? String
        else { throw HaLowError.loginRefused }
        return token
    }

    private func post(_ address: String, _ json: Any) async throws -> Data {
        guard let url = URL(string: "http://\(address)/ubus") else { throw HaLowError.notHaLow }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw HaLowError.notHaLow }
        return data
    }

    // MARK: Helpers

    /// True when `iwinfo info` or an inline `iwinfo` object describes a HaLow (sub-GHz) radio.
    /// Detection: `hwmodes` contains "ah", else frequency below 1 GHz (normalized from kHz when ≥ 100,000).
    static func isHaLow(_ info: [String: Any]?) -> Bool {
        guard let info else { return false }
        if let hwmodes = info["hwmodes"] as? [String], hwmodes.contains("ah") { return true }
        guard var mhz = int(info["frequency"]), mhz > 0 else { return false }
        if mhz >= 100_000 { mhz /= 1000 }
        return mhz < 1000
    }

    private func forget(_ address: String) {
        found[address] = nil
        stats[address] = nil
        states[address] = nil
        answered.remove(address)
        tokens[address] = nil
        meshTokens[address] = nil
        radios[address] = nil
        hostnames[address] = nil
        counters[address] = nil
        lastPolled[address] = nil
        refusedPasswords[address] = nil
        attached.remove(address)
        leaseHolders.remove(address)
        leasesDue.remove(address)
    }

    private func publish() {
        onChange?(currentNodes())
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return value as? Int
    }
}

// MARK: - Devices on the mesh

extension HaLowMonitor {
    /// The devices every answering node knows: its DHCP leases (`luci-rpc getDHCPLeases`) and its static leases
    /// (`uci get dhcp`, type host), one batch per node under the monitor's sessions. Both are in OpenWrt's stock LuCI
    /// ACLs. Nodes added by hand that aren't answering say why.
    public func meshDevices() async -> MeshDeviceScan {
        guard settings.displayMode != .off else { return MeshDeviceScan() }
        var leases: [MeshDevice] = []
        var staticLeases: [MeshDeviceList.StaticLease] = []
        var problems: [String: String] = [:]
        let now = Date()
        let password = self.password
        for address in knownAddresses {
            guard let password else {
                if settings.manualAddresses.contains(address) { problems[address] = "Needs the nodes' password (Settings → HaLow Nodes)." }
                continue
            }
            if refusedPasswords[address] == password {
                problems[address] = Self.refused
                continue
            }
            guard states[address] == .polling || settings.manualAddresses.contains(address) else { continue }
            do {
                let replies = try await call(address, password: password, [
                    UbusCall("luci-rpc", "getDHCPLeases", ["family": 4]),
                    UbusCall("uci", "get", ["config": "dhcp", "type": "host"]),
                ])
                let node = hostnames[address] ?? address
                if let items = replies[0].object?["dhcp_leases"] as? [[String: Any]] {
                    leases += MeshDeviceList.leases(items, node: node, now: now)
                    noteLeases(items, on: address)
                } else {
                    problems[address] = "Won't let this account read its DHCP leases (rpcd ACL)."
                }
                if let values = replies[1].object?["values"] as? [String: Any] {
                    staticLeases += MeshDeviceList.staticLeases(values)
                }
            } catch HaLowError.loginRefused {
                problems[address] = Self.refused
            } catch {
                problems[address] = "No answer."
            }
        }
        return MeshDeviceScan(devices: MeshDeviceList.merge(leases: leases, staticLeases: staticLeases), problems: problems)
    }

    private static let refused = "The password was refused."
}

enum HaLowError: Error {
    case loginRefused
    case accessDenied
    case notHaLow
}

/// Refuses HTTP redirects: a node never sends one, and following it would resend a login to wherever it points.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

