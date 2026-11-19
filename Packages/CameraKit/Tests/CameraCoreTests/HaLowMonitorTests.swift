import Foundation
import Testing
@testable import CameraCore

// MARK: - Fake node

/// One associated station, with every field rpcd's iwinfo assoclist sends (rpcd iwinfo.c L548–581), so byte counts
/// are realistic. Rates are kbit/s, as rpcd reports them.
struct FakeStation {
    var mac: String
    var signal: Int
    var noise: Int
    var rateKbps: Int
    var mcs: Int
    var mhz: Int
    var packets: Int
    var retries: Int

    var json: [String: Any] {
        func rate(packets: Int, extra: [String: Any]) -> [String: Any] {
            ["packets": packets, "bytes": packets * 250, "ht": true, "vht": false, "he": false, "eht": false,
             "mhz": mhz, "rate": rateKbps, "mcs": mcs, "40mhz": false, "short_gi": false].merging(extra) { a, _ in a }
        }
        return ["mac": mac, "signal": signal, "signal_avg": signal, "noise": noise, "inactive": 120,
                "connected_time": 3600, "thr": 0, "authorized": true, "authenticated": true, "preamble": "long",
                "wme": true, "mfp": false, "tdls": false, "mesh llid": 0, "mesh plid": 0, "mesh plink": "ESTAB",
                "mesh local PS": "ACTIVE", "mesh peer PS": "ACTIVE", "mesh non-peer PS": "ACTIVE",
                "rx": rate(packets: packets * 2, extra: ["drop_misc": 0]),
                "tx": rate(packets: packets, extra: ["failed": 0, "retries": retries])]
    }
}

/// An OpenMANET node: uhttpd-mod-ubus and rpcd on port 80 (JSON-RPC batches, sessions that can expire: an unknown
/// session answers -32002 "Access denied", uhttpd ubus.c L104), and openmanetd's web API on port 8080.
///
/// Shaped like the real Heltec HT-HD01 (Morse Micro HaLow, OpenMANET 1.8.0):
/// - HaLow radio wlh0: no `frequency` key, `hwmodes: ["ah"]`, mode "Mesh Point"; 2.4 GHz AP phy0-ap0: `frequency`
///   in kHz (2437000), mode "Master".
/// - Stock ACLs: `luci-rpc` getWirelessDevices/getDHCPLeases, `uci get dhcp`, `iwinfo info/assoclist`, `system board`
///   allowed; `iwinfo devices` denied.
/// - openmanetd: `/auth/check` without a login; `/auth/login` gives a token, sent back as the `session` cookie;
///   NodeService/ListNodes lists the OTHER nodes.
final class FakeUbusNode: @unchecked Sendable {
    var password = "test-password"
    var hostname = "node-1"
    var radios: [(device: String, freqHz: Int?, hwmodes: [String], mode: String, bssid: String)] = [
        ("wlh0", nil, ["ah"], "Mesh Point", "0C:BF:74:00:00:01"),
        ("phy0-ap0", 2_437_000, ["b", "g", "n"], "Master", "E4:38:19:00:00:01"),
    ]
    var haLowPeer: FakeStation? = FakeStation(mac: "0C:BF:74:00:00:02", signal: -65, noise: -95, rateKbps: 3500,
                                              mcs: 7, mhz: 2, packets: 1000, retries: 50)
    /// The phone itself, on the node's 2.4 GHz AP: what "the first wlan" would report.
    var apClient = FakeStation(mac: "AA:BB:CC:00:11:22", signal: -40, noise: -92, rateKbps: 144_400, mcs: 15,
                               mhz: 20, packets: 5000, retries: 10)
    /// False: some other HTTP server (a router's web UI) at the address.
    var speaksUbus = true
    /// False: luci-rpc isn't installed (an OpenWrt build without LuCI).
    var hasLuCI = true
    var denyLuciRpc = false
    var dhcpLeases: [[String: Any]] = []
    /// uci `dhcp` sections, as `uci get` returns them.
    var dhcpSections: [String: [String: Any]] = [:]
    /// openmanetd on 8080.
    var openMANET = true
    var meshNodes: [(ip: String, hostname: String)] = []
    /// LuCI's login page (`GET /cgi-bin/luci/`, 403 before a login): a plain OpenWrt router's by default.
    var loginPage = #"<html><head><title>OpenWrt - LuCI</title><meta name="application-name" content="OpenWrt - LuCI"></head></html>"#
    /// Radios whose settings say band s1g, hwmode 11ah (the morse radio), whatever their iwinfo says.
    var s1gDevices: Set<String> = []
    /// An interface listed first on the s1g radio that's down: no iwinfo.
    var s1gDownInterface: String?
    /// Nothing listens on these ports: a connection is refused.
    var closedPorts: Set<Int> = []

    /// Heltec's firmware as it ships (2.8.5, Morse Micro's OpenWrt 23.05, theme morseargon): no openmanetd; the login
    /// page names a "MM HaLow Device"; the morse radio's settings say s1g; here a station (the factory pair's
    /// extender), its iwinfo without "ah".
    static func heltecStock(hostname: String = "HT-HD01-9880") -> FakeUbusNode {
        let node = FakeUbusNode()
        node.openMANET = false
        node.hostname = hostname
        node.loginPage = #"<html><head><title>\#(hostname) - LuCI</title><meta name="application-name" "#
            + #"content="\#(hostname) - MM HaLow Device"></head><body class="login-page"></body></html>"#
        node.radios = [("wlan1", nil, [], "Client", "0C:BF:74:00:00:09"),
                       ("wlan0", 2_437_000, ["b", "g", "n"], "Master", "E4:38:19:00:00:09")]
        node.s1gDevices = ["wlan1"]
        return node
    }
    private var sessions: Set<String> = []
    private var meshSessions: Set<String> = []

    func expireSessions() { sessions = [] }
    func expireMeshSessions() { meshSessions = [] }

    func handle(_ request: URLRequest) -> (status: Int, body: Data) {
        let url = request.url!
        if url.port == 8080 {
            guard openMANET else { return (404, Data("<html>not found</html>".utf8)) }
            return openmanetd(request)
        }
        guard speaksUbus else { return (200, Data("<html><body>Router</body></html>".utf8)) }
        if url.path == "/cgi-bin/luci" { return (403, Data(loginPage.utf8)) }  // URL.path drops the trailing /
        let json = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        if let calls = json as? [[String: Any]] { return (200, encode(calls.map(reply))) }
        if let call = json as? [String: Any] { return (200, encode(reply(call))) }
        return (400, Data())
    }

    private func encode(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    private func openmanetd(_ request: URLRequest) -> (status: Int, body: Data) {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        switch request.url!.path {
        case "/auth/check":
            return (200, encode(["username": "", "authenticated": false, "authEnabled": true]))
        case "/auth/login":
            guard body?["username"] as? String == "root", body?["password"] as? String == password else {
                return (401, encode(["error": "invalid credentials"]))
            }
            let token = UUID().uuidString
            meshSessions.insert(token)
            return (200, encode(["username": "root", "token": token]))
        case "/rpc/openmanet.service.v1.NodeService/ListNodes":
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            guard meshSessions.contains(where: { cookie == "session=\($0)" }) else {
                return (401, encode(["error": "unauthorized"]))
            }
            return (200, encode(["nodes": meshNodes.map { ["mac": "f2:00:00:00:00:00", "hostname": $0.hostname,
                                                          "ipaddr": $0.ip, "position": [:]] }]))
        default:
            return (404, Data())
        }
    }

    private func reply(_ call: [String: Any]) -> [String: Any] {
        let id = call["id"] ?? 0
        let params = call["params"] as? [Any] ?? []
        let session = params.first as? String ?? ""
        let object = params.count > 1 ? params[1] as? String : nil
        let method = params.count > 2 ? params[2] as? String : nil
        let args = params.count > 3 ? params[3] as? [String: Any] ?? [:] : [:]
        func result(_ code: Int, _ body: [String: Any]? = nil) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": body.map { [code, $0] as [Any] } ?? [code]]
        }
        func error(_ code: Int) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": code == -32002 ? "Access denied" : "Not found"]]
        }
        if object == "session", method == "login" {
            guard args["password"] as? String == password else { return result(6) }  // UBUS_STATUS_PERMISSION_DENIED
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            sessions.insert(token)
            return result(0, ["ubus_rpc_session": token, "timeout": 300, "expires": 300, "acls": [:], "data": [:]])
        }
        guard sessions.contains(session) else { return error(-32002) }
        let radio = radios.first { $0.device == args["device"] as? String }
        func iwinfo(_ radio: (device: String, freqHz: Int?, hwmodes: [String], mode: String, bssid: String)) -> [String: Any] {
            var info: [String: Any] = ["channel": 0, "noise": -95, "mode": radio.mode, "hwmodes": radio.hwmodes,
                                       "bssid": radio.bssid]
            if let freq = radio.freqHz { info["frequency"] = freq }
            return info
        }
        switch (object, method) {
        case ("system", "board"):
            return result(0, ["hostname": hostname, "kernel": "6.6.138", "model": "Heltec HT-HD01 V2"])
        case ("iwinfo", "devices"):
            return error(-32002)  // stock ACLs deny it
        case ("iwinfo", "info"):
            guard let radio else { return result(4) }  // UBUS_STATUS_NOT_FOUND
            return result(0, iwinfo(radio))
        case ("iwinfo", "assoclist"):
            guard let radio else { return result(4) }
            let haLow = radio.hwmodes.contains("ah") || s1gDevices.contains(radio.device)
            let stations = haLow || radio.mode != "Master" ? [haLowPeer].compactMap { $0 } : [apClient]
            if let mac = args["mac"] as? String {  // one station, or NOT_FOUND
                guard let station = stations.first(where: { $0.mac.lowercased() == mac.lowercased() }) else { return result(4) }
                return result(0, station.json)
            }
            return result(0, ["results": stations.map(\.json)])
        case ("luci-rpc", "getWirelessDevices"):
            guard hasLuCI else { return error(-32000) }
            if denyLuciRpc { return error(-32002) }
            var devices: [String: Any] = [:]
            for (index, radio) in radios.enumerated() {
                let mode = ["Master": "ap", "Client": "sta"][radio.mode] ?? "mesh"
                devices["radio\(index)"] = [
                    "up": true,
                    "config": s1gDevices.contains(radio.device) ? ["band": "s1g", "hwmode": "11ah", "channel": "28"]
                        : ["band": "2g", "channel": "1"],
                    "interfaces": (s1gDevices.contains(radio.device) ? s1gDownInterface.map { [["ifname": $0, "config": ["mode": "ap"]]] } ?? [] : [])
                        + [["ifname": radio.device, "config": ["mode": mode], "iwinfo": iwinfo(radio)]],
                ]
            }
            return result(0, devices)
        case ("luci-rpc", "getDHCPLeases"):
            guard hasLuCI else { return error(-32000) }
            if denyLuciRpc { return error(-32002) }
            return result(0, ["dhcp_leases": dhcpLeases])
        case ("uci", "get"):
            guard args["config"] as? String == "dhcp" else { return result(4) }
            let type = args["type"] as? String
            return result(0, ["values": dhcpSections.filter { type == nil || $0.value[".type"] as? String == type }])
        default:
            return result(3)  // UBUS_STATUS_METHOD_NOT_FOUND
        }
    }
}

/// Routes requests to fake nodes by host and logs each one; an unknown host doesn't answer. The monitor checks
/// candidates side by side, so requests can arrive at once: one lock covers the nodes and the log.
final class FakeUbusTransport: HaLowHTTPTransport, @unchecked Sendable {
    var nodes: [String: FakeUbusNode] {
        get { lock.withLock { _nodes } }
        set { lock.withLock { _nodes = newValue } }
    }
    /// Login replies wait this long, so two callers can overlap one.
    var loginDelay: Duration = .zero
    var log: [(host: String, path: String, sent: Int, received: Int)] { lock.withLock { _log } }

    private let lock = NSLock()
    private var _nodes: [String: FakeUbusNode] = [:]
    private var _log: [(host: String, path: String, sent: Int, received: Int)] = []
    private var loginHosts: [String] = []

    func requests(to host: String) -> Int { log.filter { $0.host == host }.count }
    func ubusRequests(to host: String) -> Int { log.filter { $0.host == host && $0.path == "/ubus" }.count }
    func logins(to host: String) -> Int { lock.withLock { loginHosts.filter { $0 == host }.count } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let host = url.host, let node = nodes[host],
              !node.closedPorts.contains(url.port ?? 80) else {
            throw URLError(.cannotConnectToHost)
        }
        let isLogin = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"login\"") == true
        if isLogin {
            lock.withLock { loginHosts.append(host) }
            if loginDelay != .zero { try await Task.sleep(for: loginDelay) }
        }
        let reply = lock.withLock { () -> (status: Int, body: Data) in
            let reply = node.handle(request)
            _log.append((host, url.path, request.httpBody?.count ?? 0, reply.body.count))
            return reply
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (reply.body, response)
    }
}

/// Bonjour, as the monitor sees it: these hosts, by these names.
struct FakeBrowser: HaLowNodeBrowser {
    var hits: [(address: String, name: String)]
    func browse(seconds: Double) async -> [(address: String, name: String)] { hits }
}

/// This device's addresses, changed by a test while the monitor runs.
final class LockedAddresses: @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: Set<String>
    init(_ addresses: Set<String>) { self.addresses = addresses }
    var value: Set<String> {
        get { lock.withLock { addresses } }
        set { lock.withLock { addresses = newValue } }
    }
}

/// A Keychain that won't take the one password.
final class RefusingStore: CredentialStore, @unchecked Sendable {
    let inner = InMemoryCredentialStore()
    func password(for id: UUID) -> String? { inner.password(for: id) }
    func setPassword(_ password: String?, for id: UUID) {
        if id == haLowPasswordID, password != nil { return }
        inner.setPassword(password, for: id)
    }
}

/// Counts browses, to show none happen.
final class CountingBrowser: HaLowNodeBrowser, @unchecked Sendable {
    private(set) var count = 0
    func browse(seconds: Double) async -> [(address: String, name: String)] {
        count += 1
        return []
    }
}

// MARK: - Helpers

/// Nodes added by hand at `addresses`, one password for all.
private func setUp(_ addresses: [String], gateway: String? = nil, mode: HaLowDisplayMode = .auto,
                   password: String? = "test-password", localAddresses: Set<String> = [],
                   browser: (any HaLowNodeBrowser)? = nil)
    -> (monitor: HaLowMonitor, transport: FakeUbusTransport, credentials: InMemoryCredentialStore) {
    let transport = FakeUbusTransport()
    let credentials = InMemoryCredentialStore()
    for (index, address) in addresses.enumerated() {
        let node = FakeUbusNode()
        node.hostname = "node-\(index + 1)"
        node.radios[0].bssid = String(format: "0C:BF:74:00:00:%02X", index + 1)
        transport.nodes[address] = node
    }
    credentials.setPassword(password, for: haLowPasswordID)
    let local = gateway ?? addresses.first
    let monitor = HaLowMonitor(settings: HaLowSettings(displayMode: mode, manualAddresses: addresses),
                               credentialStore: credentials, localPollInterval: 3600, remotePollInterval: 60,
                               requestTimeout: 2, gateway: { local }, localAddresses: { localAddresses },
                               browser: browser, transport: transport)
    return (monitor, transport, credentials)
}

private func state(_ monitor: HaLowMonitor, _ address: String) async -> HaLowNodeState? {
    await monitor.currentNodes().first { $0.address == address }?.state
}

private func node(_ monitor: HaLowMonitor, _ address: String) async -> HaLowNode? {
    await monitor.currentNodes().first { $0.address == address }
}

private func routeMessage(destination: [UInt8], gateway: [UInt8]) -> [UInt8] {
    func sockaddrIn(_ ip: [UInt8]) -> [UInt8] { [16, 2, 0, 0] + ip + [UInt8](repeating: 0, count: 8) }
    var header = [UInt8](repeating: 0, count: 92)  // struct rt_msghdr
    let addresses = sockaddrIn(destination) + sockaddrIn(gateway) + [0, 0, 0, 0]  // netmask: sa_len 0, padded
    let length = header.count + addresses.count
    header[0] = UInt8(length & 0xFF)
    header[1] = UInt8(length >> 8)
    header[2] = 5     // RTM_VERSION
    header[3] = 4     // RTM_GET
    header[12] = 0x7  // RTA_DST | RTA_GATEWAY | RTA_NETMASK
    return header + addresses
}

// MARK: - Polling

@Suite("HaLow monitor", .timeLimit(.minutes(1)))
struct HaLowMonitorTests {
    let node = "192.0.2.1"
    // Request counts here are rpcd's (/ubus); asking OpenMANET for the rest of the mesh is counted in the discovery suite.

    @Test("First poll: login, one discovery batch, the assoclist; every poll after that is one request")
    func steadyStateIsOneRequest() async {
        let (monitor, transport, _) = setUp([node])
        await monitor.pollPass(force: true)
        #expect(transport.ubusRequests(to: node) == 3)
        await monitor.pollPass(force: true)
        await monitor.pollPass(force: true)
        #expect(transport.ubusRequests(to: node) == 5)
        #expect(await state(monitor, node) == .polling)
    }

    @Test("Reads the HaLow radio (hwmodes:ah), not the node's 2.4 GHz access point")
    func readsTheHaLowRadio() async {
        let (monitor, _, _) = setUp([node])
        await monitor.pollPass(force: true)
        let polled = await monitor.currentNodes().first
        #expect(polled?.stats?.signalDBm == -65, "-40 would be the phone's own Wi-Fi link on phy0-ap0")
        #expect(polled?.name == "node-1")
    }

    @Test("Rate is kbit/s; noise, width and MCS come from the station; retries are since the last poll")
    func mapsTheStation() async throws {
        let (monitor, transport, _) = setUp([node])
        await monitor.pollPass(force: true)
        var stats = try #require(await monitor.currentNodes().first?.stats)
        #expect(stats.phyRateKbps == 3500)
        #expect(stats.mcsIndex == 7)
        #expect(stats.channelWidthMHz == 2)
        #expect(stats.snrDB == 30)
        #expect(stats.txRetryRatio == nil, "one sample of lifetime counters says nothing about now")
        transport.nodes[node]?.haLowPeer?.packets += 95
        transport.nodes[node]?.haLowPeer?.retries += 5
        await monitor.pollPass(force: true)
        stats = try #require(await monitor.currentNodes().first?.stats)
        #expect(abs((stats.txRetryRatio ?? 0) - 0.05) < 0.0001)
    }

    @Test("An expired session logs in once more and the poll still lands")
    func expiredSessionRelogs() async {
        let (monitor, transport, _) = setUp([node])
        await monitor.pollPass(force: true)
        transport.nodes[node]?.expireSessions()
        await monitor.pollPass(force: true)
        #expect(transport.ubusRequests(to: node) == 3 + 3)  // denied, login, assoclist again
        #expect(await state(monitor, node) == .polling)
        await monitor.pollPass(force: true)
        #expect(transport.ubusRequests(to: node) == 7)
    }

    @Test("No password: nothing is sent")
    func noPasswordSendsNothing() async {
        let (monitor, transport, _) = setUp([node], password: nil)
        await monitor.pollPass(force: true)
        #expect(transport.log.isEmpty)
        #expect(await state(monitor, node) == .needsPassword)
    }

    @Test("A refused password isn't tried again until it changes")
    func refusedPasswordWaits() async {
        let (monitor, transport, credentials) = setUp([node], password: "wrong")
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .loginFailed)
        #expect(transport.ubusRequests(to: node) == 1)
        await monitor.pollPass(force: true)
        #expect(transport.ubusRequests(to: node) == 1)
        credentials.setPassword("test-password", for: haLowPasswordID)
        await monitor.passwordChanged()
        #expect(await state(monitor, node) == .polling)
    }

    @Test("A node with no HaLow radio isn't a HaLow node")
    func noHaLowRadio() async {
        let (monitor, transport, _) = setUp([node])
        transport.nodes[node]?.radios = [("wlan0", 2_437_000, ["b", "g", "n"], "Master", "E4:00:00:00:00:01"),
                                         ("wlan1", 5_180_000, ["a", "n", "ac"], "Master", "E4:00:00:00:00:02")]
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .notHaLow)
        #expect(await monitor.currentNodes().first?.stats == nil)
    }

    @Test("A radio detected only by sub-GHz frequency (MHz or kHz) is still HaLow")
    func haLowByFrequencyFallback() async {
        for freq in [915, 902_000] {  // MHz from older firmware; kHz normalized to 902 MHz
            let (monitor, transport, _) = setUp([node])
            transport.nodes[node]?.radios[0] = ("wlh0", freq, [], "Mesh Point", "0C:BF:74:00:00:01")
            await monitor.pollPass(force: true)
            #expect(await state(monitor, node) == .polling, "\(freq) should read as HaLow")
        }
    }

    @Test("A node without LuCI's rpcd calls can't be read: Access denied")
    func withoutLuCI() async {
        let (monitor, transport, _) = setUp([node])
        transport.nodes[node]?.hasLuCI = false
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .accessDenied)
    }

    @Test("Nothing that reads the radios is allowed: Access denied, and the password isn't held against it")
    func accessDenied() async {
        let (monitor, transport, _) = setUp([node])
        transport.nodes[node]?.denyLuciRpc = true
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .accessDenied)
        transport.nodes[node]?.denyLuciRpc = false
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .polling, "once the ACL allows it, the same password works")
    }

    @Test("An HTTP server that isn't rpcd isn't a HaLow node; no answer is unreachable; no peer is a link down")
    func otherAnswers() async {
        let (notUbus, notUbusTransport, _) = setUp([node])
        notUbusTransport.nodes[node]?.speaksUbus = false
        await notUbus.pollPass(force: true)
        #expect(await state(notUbus, node) == .notHaLow)

        let (gone, goneTransport, _) = setUp([node])
        goneTransport.nodes = [:]
        await gone.pollPass(force: true)
        #expect(await state(gone, node) == .unreachable)

        let (lonely, lonelyTransport, _) = setUp([node])
        lonelyTransport.nodes[node]?.haLowPeer = nil
        await lonely.pollPass(force: true)
        #expect(await state(lonely, node) == .polling)
        #expect(await lonely.currentNodes().first?.stats?.signalDBm == nil)
    }

    @Test("Off and background send nothing")
    func offAndBackground() async {
        let off = setUp([node], mode: .off)
        await off.monitor.pollPass(force: true)
        #expect(off.transport.log.isEmpty)

        let background = setUp([node])
        await background.monitor.setForeground(false)
        await background.monitor.pollPass(force: true)
        #expect(background.transport.log.isEmpty)
    }

    @Test("The node this device is on is polled every pass; a node across the HaLow link once a minute")
    func remoteCadence() async {
        let remote = "192.0.2.2"
        let (monitor, transport, _) = setUp([node, remote], gateway: node)
        let start = Date()
        await monitor.pollPass(force: false, now: start)
        #expect(transport.ubusRequests(to: node) == 3)
        #expect(transport.ubusRequests(to: remote) == 3)
        await monitor.pollPass(force: false, now: start.addingTimeInterval(10))
        #expect(transport.ubusRequests(to: node) == 4)
        #expect(transport.ubusRequests(to: remote) == 3)
        await monitor.pollPass(force: false, now: start.addingTimeInterval(61))
        #expect(transport.ubusRequests(to: node) == 5)
        #expect(transport.ubusRequests(to: remote) == 4)
    }

    @Test("Budget: a steady-state poll is one request of about 1.5 KB")
    func steadyStateBudget() async throws {
        let (monitor, transport, _) = setUp([node])
        await monitor.pollPass(force: true)
        let before = transport.log.count
        await monitor.pollPass(force: true)
        #expect(transport.log.count == before + 1)
        let poll = try #require(transport.log.last)
        // Headers are estimates: URLSession's request (POST line, Host, Content-Type/Length, Accept, Accept-Language,
        // Accept-Encoding, User-Agent, Connection) ~300 B; uhttpd's reply (status, Connection, Transfer-Encoding,
        // Keep-Alive, Content-Type, chunk framing) ~150 B.
        let sent = poll.sent + 300
        let received = poll.received + 150
        print("HaLow steady-state poll: 1 request, \(sent) B out + \(received) B in = \(sent + received) B (one peer)")
        #expect(sent + received < 2000)
    }

    @Test("One login per node, however many callers want a session at once")
    func oneLoginAtATime() async {
        let (monitor, transport, _) = setUp([node])
        transport.loginDelay = .milliseconds(50)
        async let poll: Void = monitor.pollNow()
        async let scan = monitor.meshDevices()
        _ = await (poll, scan)
        #expect(transport.logins(to: node) == 1)
    }

    @Test("isHaLow: hwmodes:ah, sub-GHz MHz, sub-GHz kHz — and not 2.4 GHz")
    func isHaLowDetection() {
        #expect(HaLowMonitor.isHaLow(["hwmodes": ["ah"]]))
        #expect(HaLowMonitor.isHaLow(["frequency": 915]))        // MHz
        #expect(HaLowMonitor.isHaLow(["frequency": 902_000]))    // kHz
        #expect(!HaLowMonitor.isHaLow(["hwmodes": ["b", "g", "n"], "frequency": 2_437_000]))
        #expect(!HaLowMonitor.isHaLow(nil))
        #expect(!HaLowMonitor.isHaLow([:]))
    }

    @Test("The default gateway is the gateway of the 0.0.0.0 route")
    func defaultGatewayFromRoutingMessages() {
        let other = routeMessage(destination: [192, 168, 5, 0], gateway: [192, 0, 2, 9])
        let defaultRoute = routeMessage(destination: [0, 0, 0, 0], gateway: [192, 0, 2, 1])
        #expect(DefaultGateway.parse(other + defaultRoute) == "192.0.2.1")
        #expect(DefaultGateway.parse(other) == nil)
        #expect(DefaultGateway.parse([]) == nil)
    }

    @Test("Settings saved when every node was added by hand load as nodes added by hand; their password moves")
    func oldSettingsMigrate() throws {
        let json = #"{"displayMode":"on","nodeAddresses":["192.0.2.1","192.0.2.2"],"username":"root"}"#
        let settings = try JSONDecoder().decode(HaLowSettings.self, from: Data(json.utf8))
        #expect(settings == HaLowSettings(displayMode: .on, manualAddresses: ["192.0.2.1", "192.0.2.2"]))
        let credentials = InMemoryCredentialStore()
        credentials.setPassword("test-password", for: legacyHaLowPasswordID(for: "192.0.2.2"))
        settings.migrateLegacyPasswords(in: credentials)
        #expect(credentials.password(for: haLowPasswordID) == "test-password")
        #expect(credentials.password(for: legacyHaLowPasswordID(for: "192.0.2.2")) == nil)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(reencoded?["nodeAddresses"] as? [String] == ["192.0.2.1", "192.0.2.2"])

        let refusing = RefusingStore()
        refusing.setPassword("test-password", for: legacyHaLowPasswordID(for: "192.0.2.1"))
        settings.migrateLegacyPasswords(in: refusing)
        #expect(refusing.password(for: legacyHaLowPasswordID(for: "192.0.2.1")) == "test-password",
                "a password the Keychain didn't take isn't deleted from where it was")
    }
}

// MARK: - Finding nodes

@Suite("HaLow node discovery", .timeLimit(.minutes(1)))
struct HaLowDiscoveryTests {
    /// A mesh of OpenMANET nodes at `addresses`, none added by hand; Bonjour sees `visible`.
    private func mesh(_ addresses: [String], visible: [(address: String, name: String)], password: String? = "test-password",
                      gateway: String? = nil, localAddresses: Set<String> = [])
        -> (monitor: HaLowMonitor, transport: FakeUbusTransport, credentials: InMemoryCredentialStore) {
        let transport = FakeUbusTransport()
        for (index, address) in addresses.enumerated() {
            let node = FakeUbusNode()
            node.hostname = "node-\(index + 1)"
            node.radios[0].bssid = String(format: "0C:BF:74:00:00:%02X", index + 1)
            node.meshNodes = addresses.enumerated().filter { $0.element != address }.map { ($0.element, "node-\($0.offset + 1)") }
            transport.nodes[address] = node
        }
        let credentials = InMemoryCredentialStore()
        credentials.setPassword(password, for: haLowPasswordID)
        let monitor = HaLowMonitor(settings: HaLowSettings(), credentialStore: credentials, localPollInterval: 3600,
                                   remotePollInterval: 60, requestTimeout: 2, gateway: { gateway },
                                   localAddresses: { localAddresses }, browser: FakeBrowser(hits: visible),
                                   transport: transport)
        return (monitor, transport, credentials)
    }

    @Test("Bonjour finds one node; it lists the rest of the mesh; a printer gets two GETs and nothing else")
    func findingOneFindsThemAll() async {
        let (monitor, transport, _) = mesh(["192.0.2.1", "192.0.2.2", "192.0.2.3"],
                                           visible: [("192.0.2.1", "node-1"), ("192.0.2.50", "Printer")])
        let printer = FakeUbusNode()
        printer.openMANET = false
        printer.speaksUbus = false
        transport.nodes["192.0.2.50"] = printer
        await monitor.findNodes()
        let nodes = await monitor.currentNodes()
        #expect(nodes.map(\.address) == ["192.0.2.1", "192.0.2.2", "192.0.2.3"])
        #expect(nodes.allSatisfy { $0.state == .polling && !$0.isManual })
        #expect(nodes.map(\.name) == ["node-1", "node-2", "node-3"])
        #expect(transport.log.filter { $0.host == "192.0.2.50" }.map(\.path).sorted() == ["/auth/check", "/cgi-bin/luci"])
        #expect(transport.ubusRequests(to: "192.0.2.2") == 3, "node 2 needed no check: node 1 vouched for it")
    }

    @Test("A Heltec node as it ships: its login page vouches for it, and its radio is HaLow by its band")
    func heltecStockStation() async {
        let (monitor, transport, _) = mesh([], visible: [], gateway: "10.42.0.1", localAddresses: ["10.42.0.100"])
        let station = FakeUbusNode.heltecStock()
        station.closedPorts = [8080]
        station.s1gDownInterface = "wlan2"  // listed first on the s1g radio, and down
        transport.nodes["10.42.0.1"] = station
        await monitor.findNodes()
        let stock = await node(monitor, "10.42.0.1")
        #expect(stock?.state == .polling && stock?.name == "HT-HD01-9880" && stock?.isLocal == true)
        #expect(stock?.stats?.signalDBm == -65 && stock?.stats?.phyRateKbps == 3500, "the station's link to its access point")
        #expect(transport.log.filter { $0.path == "/cgi-bin/luci" }.count == 1)
        #expect(transport.log.allSatisfy { $0.path != "/auth/check" && $0.path != "/auth/login" }, "8080 refused")
    }

    @Test("The check: a login page without the marker is a no; silence on port 80 is never a no")
    func checkOutcomes() async {
        let transport = FakeUbusTransport()
        let openMANET = FakeUbusNode()
        let stock = FakeUbusNode.heltecStock()
        stock.closedPorts = [8080]
        let router = FakeUbusNode()
        router.openMANET = false
        router.closedPorts = [8080]
        let quietWeb = FakeUbusNode()  // something answers on 8080 (not OpenMANET), and port 80 is silent
        quietWeb.openMANET = false
        quietWeb.closedPorts = [80]
        let rethemed = FakeUbusNode()  // a page that merely mentions the words
        rethemed.openMANET = false
        rethemed.loginPage = "<html><body>Looking for an MM HaLow Device? Try our shop.</body></html>"
        transport.nodes = ["192.0.2.1": openMANET, "192.0.2.2": stock, "192.0.2.3": router, "192.0.2.4": quietWeb,
                           "192.0.2.5": rethemed]
        func check(_ address: String) async -> HaLowMonitor.NodeCheck {
            await HaLowMonitor.identify(address, transport: transport, timeout: 1)
        }
        #expect(await check("192.0.2.1") == .node(.openMANET))
        #expect(await check("192.0.2.2") == .node(.morse))
        #expect(await check("192.0.2.3") == .notANode)
        #expect(await check("192.0.2.4") == .noAnswer)
        #expect(await check("192.0.2.5") == .notANode)
        #expect(await check("192.0.2.9") == .noAnswer, "nothing there")
    }

    @Test("The factory pair's access point: the HaLow AP lists the station; the 2.4 GHz AP's phone isn't the link")
    func heltecStockAccessPoint() async {
        let (monitor, transport, _) = mesh([], visible: [], gateway: "192.168.100.1", localAddresses: ["192.168.100.120"])
        let accessPoint = FakeUbusNode.heltecStock(hostname: "HT-HD01-9958")
        accessPoint.radios = [("wlan0", 2_437_000, ["b", "g", "n"], "Master", "E4:38:19:00:00:0A"),
                              ("wlan1", nil, ["ah"], "Master", "0C:BF:74:00:00:0A")]
        transport.nodes["192.168.100.1"] = accessPoint
        await monitor.findNodes()
        let found = await node(monitor, "192.168.100.1")
        #expect(found?.state == .polling && found?.stats?.signalDBm == -65)
    }

    @Test("An rpcd host that isn't a HaLow node (no OpenMANET, a plain LuCI login page) never gets the password")
    func plainOpenWrtIsLeftAlone() async {
        let (monitor, transport, _) = mesh([], visible: [("192.0.2.9", "OpenWrt")], gateway: "192.0.2.9")
        let router = FakeUbusNode()
        router.openMANET = false
        transport.nodes["192.0.2.9"] = router
        await monitor.findNodes()
        await monitor.pollNow()
        #expect(await monitor.currentNodes().isEmpty)
        #expect(transport.ubusRequests(to: "192.0.2.9") == 0)
    }

    @Test("No password: nothing is looked for; Settings looking lists what's there and sends no password")
    func lookingWithoutAPassword() async {
        let browser = CountingBrowser()
        let quiet = HaLowMonitor(settings: HaLowSettings(), credentialStore: InMemoryCredentialStore(),
                                 gateway: { nil }, localAddresses: { [] }, browser: browser, transport: FakeUbusTransport())
        await quiet.setForeground(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(browser.count == 0)

        let (monitor, transport, _) = mesh(["192.0.2.1"], visible: [("192.0.2.1", "node-1")], password: nil)
        await monitor.findNodes()
        let nodes = await monitor.currentNodes()
        #expect(nodes.map(\.name) == ["node-1"] && nodes.first?.state == .needsPassword)
        #expect(Set(transport.log.map(\.path)).isSubset(of: ["/auth/check", "/cgi-bin/luci"]),
                "the two password-free checks, side by side, and nothing else")
    }

    @Test("The mesh's list is asked for once, then every 5 min; an expired OpenMANET login logs in again")
    func meshListCadence() async {
        let (monitor, transport, _) = mesh(["192.0.2.1", "192.0.2.2"], visible: [("192.0.2.1", "node-1")])
        func lists() -> Int { transport.log.filter { $0.path.hasSuffix("/ListNodes") }.count }
        func meshLogins() -> Int { transport.log.filter { $0.path == "/auth/login" }.count }
        let start = Date()
        await monitor.findNodes()
        #expect(lists() == 1 && meshLogins() == 1)
        await monitor.pollPass(force: false, now: start.addingTimeInterval(120))
        #expect(lists() == 1)
        transport.nodes["192.0.2.1"]?.expireMeshSessions()
        await monitor.pollPass(force: false, now: start.addingTimeInterval(301))
        #expect(lists() == 3 && meshLogins() == 2, "401, log in, list again")
    }

    @Test("A node the mesh lists that doesn't answer stays hidden, and is checked again with the next list")
    func listedButOff() async {
        let (monitor, transport, _) = mesh(["192.0.2.1"], visible: [("192.0.2.1", "node-1")])
        transport.nodes["192.0.2.1"]?.meshNodes = [("192.0.2.7", "node-7")]  // listed, but off
        await monitor.findNodes()
        #expect(await monitor.currentNodes().map(\.address) == ["192.0.2.1"])
        transport.nodes["192.0.2.7"] = FakeUbusNode()  // it comes back
        await monitor.pollPass(force: false, now: Date().addingTimeInterval(62))
        #expect(await node(monitor, "192.0.2.7") == nil)
        await monitor.pollPass(force: false, now: Date().addingTimeInterval(301))
        #expect(await node(monitor, "192.0.2.7")?.state == .polling)
    }

    @Test("A found node that stops answering is tried again after a minute, then two")
    func backOff() async {
        let (monitor, transport, _) = mesh(["192.0.2.1"], visible: [("192.0.2.1", "node-1")])
        await monitor.findNodes()
        let node1 = transport.nodes["192.0.2.1"]
        transport.nodes["192.0.2.1"] = nil
        let start = Date().addingTimeInterval(61)
        await monitor.pollPass(force: false, now: start)
        #expect(await state(monitor, "192.0.2.1") == .unreachable)
        transport.nodes["192.0.2.1"] = node1
        await monitor.pollPass(force: false, now: start.addingTimeInterval(30))
        #expect(await state(monitor, "192.0.2.1") == .unreachable, "not before its minute is up")
        await monitor.pollPass(force: false, now: start.addingTimeInterval(61))
        #expect(await state(monitor, "192.0.2.1") == .polling)
    }

    @Test("An address the mesh lists gets the same check: a host that isn't OpenMANET never gets the password")
    func listedHostsAreChecked() async {
        let (monitor, transport, _) = mesh(["192.0.2.1"], visible: [("192.0.2.1", "node-1")])
        let router = FakeUbusNode()
        router.openMANET = false
        transport.nodes["192.0.2.9"] = router
        transport.nodes["192.0.2.1"]?.meshNodes = [("192.0.2.9", "router")]
        await monitor.findNodes()
        #expect(await node(monitor, "192.0.2.9") == nil)
        #expect(transport.ubusRequests(to: "192.0.2.9") == 0)
    }

    @Test("Started with only a password, it looks for nodes by itself")
    func startsLooking() async {
        let browser = CountingBrowser()
        let credentials = InMemoryCredentialStore()
        credentials.setPassword("test-password", for: haLowPasswordID)
        let monitor = HaLowMonitor(settings: HaLowSettings(), credentialStore: credentials, gateway: { nil },
                                   localAddresses: { [] }, browser: browser, transport: FakeUbusTransport())
        await monitor.setForeground(true)
        for _ in 0..<50 where browser.count == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.count == 1)
        await monitor.setForeground(false)
    }

    @Test("One node at two addresses is polled once, at the address the mesh lists")
    func sameNodeTwice() async {
        let (monitor, transport, _) = mesh(["192.0.2.1", "192.0.2.2"],
                                           visible: [("198.51.100.2", "node-2"), ("192.0.2.1", "node-1")])
        transport.nodes["198.51.100.2"] = transport.nodes["192.0.2.2"]  // node 2's other interface
        await monitor.findNodes()
        await monitor.pollNow()
        #expect(await monitor.currentNodes().map(\.address) == ["192.0.2.1", "192.0.2.2"])
    }

    @Test("HaLow stations sharing their AP's BSSID are still two nodes")
    func sharedBSSID() async {
        let (monitor, transport, _) = mesh(["192.0.2.1", "192.0.2.2"], visible: [("192.0.2.1", "node-1")])
        for address in ["192.0.2.1", "192.0.2.2"] {
            transport.nodes[address]?.radios[0] = ("wlh0", nil, ["ah"], "Client", "0C:BF:74:00:00:AA")
        }
        await monitor.findNodes()
        #expect(await monitor.currentNodes().map(\.address) == ["192.0.2.1", "192.0.2.2"])
    }

    @Test("A box that answers OpenMANET's check but has no HaLow radio is dropped")
    func notHaLowIsDropped() async {
        let (monitor, transport, _) = mesh(["192.0.2.1"], visible: [("192.0.2.1", "node-1")])
        transport.nodes["192.0.2.1"]?.radios = [("phy0-ap0", 2_437_000, ["b", "g", "n"], "Master", "E4:00:00:00:00:01")]
        await monitor.findNodes()
        #expect(await monitor.currentNodes().isEmpty)
    }

    @Test("This device's node: on its Wi-Fi beats holding its lease; it's listed first")
    func thisDevicesNode() async {
        let (monitor, transport, _) = mesh(["192.0.2.1", "192.0.2.2", "192.0.2.3"],
                                           visible: [("192.0.2.1", "node-1")], localAddresses: ["192.0.2.150"])
        transport.nodes["192.0.2.2"]?.dhcpLeases = [["ipaddr": "192.0.2.150", "macaddr": "AA:BB:CC:00:11:22", "expires": 200]]
        transport.nodes["192.0.2.1"]?.apClient.mac = "02:00:00:00:00:99"
        transport.nodes["192.0.2.2"]?.apClient.mac = "02:00:00:00:00:98"
        transport.nodes["192.0.2.3"]?.apClient.mac = "02:00:00:00:00:97"
        await monitor.findNodes()
        #expect(await monitor.currentNodes().first?.address == "192.0.2.2", "node 2 gave this device its address")
        transport.nodes["192.0.2.3"]?.apClient.mac = "AA:BB:CC:00:11:22"  // it walked over to node 3's Wi-Fi
        await monitor.pollNow()
        let nodes = await monitor.currentNodes()
        #expect(nodes.first?.address == "192.0.2.3" && nodes.first?.isLocal == true)
        #expect(nodes.filter(\.isLocal).count == 1)
    }

    @Test("On a cable, the node holding this device's lease is its node, and a new address moves it")
    func leaseMoves() async {
        let addresses = LockedAddresses(["192.0.2.150"])
        let transport = FakeUbusTransport()
        for (index, address) in ["192.0.2.1", "192.0.2.2"].enumerated() {
            let node = FakeUbusNode()
            node.hostname = "node-\(index + 1)"
            node.radios[0].bssid = String(format: "0C:BF:74:00:00:%02X", index + 1)
            node.meshNodes = [index == 0 ? ("192.0.2.2", "node-2") : ("192.0.2.1", "node-1")]
            transport.nodes[address] = node
        }
        transport.nodes["192.0.2.1"]?.dhcpLeases = [["ipaddr": "192.0.2.150", "macaddr": "AA:00:00:00:00:01", "expires": 200]]
        let credentials = InMemoryCredentialStore()
        credentials.setPassword("test-password", for: haLowPasswordID)
        let monitor = HaLowMonitor(settings: HaLowSettings(), credentialStore: credentials, localPollInterval: 3600,
                                   gateway: { nil }, localAddresses: { addresses.value },
                                   browser: FakeBrowser(hits: [("192.0.2.1", "node-1")]), transport: transport)
        await monitor.findNodes()
        #expect(await monitor.currentNodes().first?.address == "192.0.2.1")
        // Plugged into node 2: a lease from it, a new address here.
        transport.nodes["192.0.2.1"]?.dhcpLeases = []
        transport.nodes["192.0.2.2"]?.dhcpLeases = [["ipaddr": "192.0.2.230", "macaddr": "AA:00:00:00:00:01", "expires": 200]]
        addresses.value = ["192.0.2.230"]
        await monitor.pollPass(force: true)
        #expect(await monitor.currentNodes().first?.address == "192.0.2.2")
    }
}

// MARK: - Devices on the mesh

@Suite("HaLow mesh devices", .timeLimit(.minutes(1)))
struct MeshDeviceTests {
    @Test("Every node's leases and static leases, one request per node: names, cameras first, a moved device once")
    func listsTheMesh() async {
        let (monitor, transport, _) = setUp(["192.0.2.1", "192.0.2.2"])
        let one = transport.nodes["192.0.2.1"]!, two = transport.nodes["192.0.2.2"]!
        let statics: [String: [String: Any]] = [
            "cfg01": [".type": "host", "name": "camera-a", "mac": "a0:cd:f3:00:00:02 00:e0:4c:00:00:02", "ip": "192.0.2.102"],
            "cfg02": [".type": "host", "name": "monitor", "mac": ["02:00:00:00:00:20"], "ip": "192.0.2.20"],
            "lan": [".type": "dhcp", "interface": "lan", "start": "100"],
        ]
        one.dhcpSections = statics
        two.dhcpSections = statics
        one.dhcpLeases = [["ipaddr": "192.0.2.102", "macaddr": "A0:CD:F3:00:00:02", "hostname": "camera-a", "expires": 250],
                          ["ipaddr": "192.0.2.150", "macaddr": "DE:AD:BE:EF:00:01", "hostname": "iPhone", "expires": 280]]
        two.dhcpLeases = [["ipaddr": "192.0.2.230", "macaddr": "A0:CD:F3:00:00:02", "hostname": "camera-a", "expires": 10],
                          ["ipaddr": "192.0.2.137", "macaddr": "7C:2E:0D:00:00:30", "expires": false],
                          ["ipaddr": "192.0.2.138", "macaddr": "02:00:00:00:00:38", "hostname": "SonyImagingDevice", "expires": 99]]
        await monitor.pollPass(force: true)  // the sessions a running monitor already has
        let before = (transport.requests(to: "192.0.2.1"), transport.requests(to: "192.0.2.2"))
        let scan = await monitor.meshDevices()
        #expect(transport.requests(to: "192.0.2.1") == before.0 + 1)
        #expect(transport.requests(to: "192.0.2.2") == before.1 + 1)
        #expect(scan.problems.isEmpty)
        #expect(scan.devices.map(\.ip) == ["192.0.2.137", "192.0.2.138", "192.0.2.20", "192.0.2.102", "192.0.2.150"])
        let pyxis = scan.devices[0], sony = scan.devices[1], monitorRow = scan.devices[2], fx3 = scan.devices[3]
        #expect(pyxis.cameraMaker == .blackmagic && pyxis.name == nil && pyxis.leaseExpires == nil && pyxis.node == "node-2")
        #expect(sony.cameraMaker == .sony)
        #expect(monitorRow.staticName == "monitor" && !monitorRow.isPresent)
        // The FX3 moved: node 2's older lease gives way to node 1's newer one on its static address.
        #expect(fx3.staticName == "camera-a" && fx3.node == "node-1" && fx3.mac == "a0:cd:f3:00:00:02")
        #expect(scan.devices[4].name == "iPhone" && scan.devices[4].cameraMaker == nil)
    }

    @Test("A node that won't let the account read its leases says so; monitoring carries on")
    func readDeniedIsNotABadPassword() async {
        let node = "192.0.2.1"
        let (monitor, transport, _) = setUp([node])
        await monitor.pollPass(force: true)
        transport.nodes[node]!.denyLuciRpc = true
        let scan = await monitor.meshDevices()
        #expect(scan.devices.isEmpty)
        #expect(scan.problems[node]?.contains("DHCP leases") == true)
        transport.nodes[node]!.denyLuciRpc = false
        await monitor.pollPass(force: true)
        #expect(await state(monitor, node) == .polling, "monitoring carries on with the same password")
    }

    @Test("Nodes added by hand say why: no password, a refused one, no answer; Off asks nothing")
    func problems() async {
        let (monitor, transport, _) = setUp(["192.0.2.1", "192.0.2.2"])
        transport.nodes["192.0.2.1"]!.password = "something else"
        transport.nodes["192.0.2.2"] = nil
        await monitor.pollPass(force: true)
        let scan = await monitor.meshDevices()
        #expect(scan.problems["192.0.2.1"] == "The password was refused.")
        #expect(scan.problems["192.0.2.2"] == "No answer.")

        let (unset, _, _) = setUp(["192.0.2.1"], password: nil)
        #expect(await unset.meshDevices().problems["192.0.2.1"]?.contains("password") == true)

        let (off, offTransport, _) = setUp(["192.0.2.1"], mode: .off)
        #expect(await off.meshDevices() == MeshDeviceScan())
        #expect(offTransport.requests(to: "192.0.2.1") == 0)
    }

    @Test("Static leases: a MAC string or list, non-host sections and bad addresses skipped")
    func staticLeases() {
        let rows = MeshDeviceList.staticLeases([
            "a": [".type": "host", "name": "one", "mac": "AA:00:00:00:00:01 aa:00:00:00:00:02", "ip": "192.0.2.11"],
            "b": [".type": "host", "mac": ["aa:00:00:00:00:03"], "ip": "192.0.2.12"],
            "c": [".type": "host", "name": "no-ip", "mac": "aa:00:00:00:00:04"],
            "d": [".type": "host", "name": "bad", "mac": "aa:00:00:00:00:05", "ip": "192.0.2.999"],
            "e": [".type": "domain", "name": "x", "ip": "192.0.2.13"],
        ])
        #expect(rows == [MeshDeviceList.StaticLease(name: "one", macs: ["aa:00:00:00:00:01", "aa:00:00:00:00:02"], ip: "192.0.2.11"),
                         MeshDeviceList.StaticLease(name: nil, macs: ["aa:00:00:00:00:03"], ip: "192.0.2.12")])
    }

    @Test("getDHCPLeases: expires false or 0 is no expiry, seconds remaining is a date; MACs lower-cased")
    func luciRpcLeaseConversion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let leases = MeshDeviceList.leases([
            ["ipaddr": "192.0.2.1", "macaddr": "AA:BB:CC:DD:EE:01", "expires": 300],
            ["ipaddr": "192.0.2.2", "macaddr": "AA:BB:CC:DD:EE:02", "expires": false as Any],
            ["ipaddr": "192.0.2.3", "macaddr": "AA:BB:CC:DD:EE:03", "expires": 0, "hostname": ""],
            ["ipaddr": "not-an-ip", "macaddr": "AA:BB:CC:DD:EE:04"],
        ], node: "n", now: now)
        #expect(leases.count == 3)
        #expect(leases[0].leaseExpires == now.addingTimeInterval(300))
        #expect(leases[1].leaseExpires == nil && leases[2].leaseExpires == nil && leases[2].hostname == nil)
        #expect(leases.allSatisfy { $0.mac == $0.mac.lowercased() })
    }

    @Test("Cameras by what they say: Sony's DHCP name, Blackmagic's and Sony Imaging's OUIs; nothing else")
    func cameraMakers() {
        #expect(MeshDeviceList.cameraMaker(hostname: "SonyImagingDevice", mac: "a0:cd:f3:00:00:01") == .sony)
        #expect(MeshDeviceList.cameraMaker(hostname: nil, mac: "7C:2E:0D:12:34:56") == .blackmagic)
        #expect(MeshDeviceList.cameraMaker(hostname: nil, mac: "2c:97:ed:00:00:01") == .sony)
        #expect(MeshDeviceList.cameraMaker(hostname: "camera-a", mac: "a0:cd:f3:00:00:01") == nil)
    }
}
