// Basic transport-level tests that avoid the full session complexity.

import Testing
import Foundation
import Network
@testable import SonyPTP
import CameraCore

@Suite("Transport Tests", .serialized)
struct TransportTests {

    @Test("Transport connects and receives Init_Command_Ack", .timeLimit(.minutes(1)))
    func transportConnects() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        let guid = UUID()
        var cfg = PTPIPTransportConfig()
        cfg.port = NWEndpoint.Port(rawValue: cam.port)!
        cfg.connectTimeout = 5
        let transport = PTPIPTransport(host: "127.0.0.1", config: cfg)

        try await transport.connect(guid: guid, friendlyName: "test")
        #expect(transport.state == .connected)
    }

    @Test("Transport can execute OpenSession after connect", .timeLimit(.minutes(1)))
    func transportOpenSession() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        let guid = UUID()
        var cfg = PTPIPTransportConfig()
        cfg.port = NWEndpoint.Port(rawValue: cam.port)!
        cfg.connectTimeout = 5
        let transport = PTPIPTransport(host: "127.0.0.1", config: cfg)

        try await transport.connect(guid: guid, friendlyName: "test")
        transport.startReceiving()

        let (resp, _) = try await transport.execute(opCode: PTPOpCode.openSession.rawValue, params: [1])
        #expect(resp.responseCode == PTPResponseCode.ok.rawValue)
    }

    @Test("Session open sequence completes", .timeLimit(.minutes(1)))
    func sessionOpen() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        let guid = UUID()
        var tCfg = PTPIPTransportConfig()
        tCfg.port = NWEndpoint.Port(rawValue: cam.port)!
        tCfg.connectTimeout = 5
        let transport = PTPIPTransport(host: "127.0.0.1", config: tCfg)

        try await transport.connect(guid: guid, friendlyName: "test")
        let session = PTPIPSession(transport: transport)
        let info = try await session.open()
        #expect(info.extDeviceInfo.extensionVersion == 0x0136)  // FakePTPIPCamera reports 3.10 [FX3 v7]
    }
}
