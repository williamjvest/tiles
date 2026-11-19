// PTP-IP session: OpenSession, SDIO_Connect sequence, SDIO_GetExtDeviceInfo (with retry),
// optional SDIO_OpenSession, CloseSession. [Architecture rule 3, §3]

import Foundation

// MARK: - Session Configuration

public struct SessionConfig: Sendable {
    /// SessionID for OpenSession: always 1.
    public var sessionID: UInt32 = 1
    /// Whether to call SDIO_OpenSession after the 3-phase SDIO_Connect.
    /// FX6/BURANO may not support it (docs/protocol.md, Open Questions); default true with fallback.
    public var callSDIOOpenSession: Bool = true
    /// FunctionMode for SDIO_OpenSession
    public var functionMode: SDIOFunctionMode = .remoteControl
    /// Max retry attempts for SDIO_GetExtDeviceInfo returning zero-length data
    public var extDeviceInfoMaxRetries: Int = 20
    /// Delay between retries
    public var extDeviceInfoRetryDelay: TimeInterval = 0.5
    /// Timeout for the whole retry loop
    public var extDeviceInfoRetryTimeout: TimeInterval = 10.0

    public init() {}
}

// MARK: - Session state

public struct SessionInfo: Sendable {
    public let extDeviceInfo: SDIExtDeviceInfo
    /// Response Parameter 1 from SDIO_GetExtDeviceInfo: Vendor Code Version
    public let vendorCodeVersion: UInt32
    /// Whether SDIO_OpenSession was called and succeeded
    public let sdioOpenSessionCalled: Bool
}

// MARK: - PTPIPSession

/// Runs the full Sony session setup sequence on an established link (PTP-IP or USB).
/// [§3 session setup]
public final class PTPIPSession: @unchecked Sendable {

    private let transport: any PTPTransport
    private let config: SessionConfig

    public init(transport: any PTPTransport, config: SessionConfig = SessionConfig()) {
        self.transport = transport
        self.config = config
    }

    // MARK: - Open

    /// Runs the full session open sequence.
    /// On pairing approval wait, transport.connect() will have thrown .authenticationFailed —
    /// the caller (SonyCameraBackend) surfaces ConnectionState.awaitingApproval. [Architecture rule 4]
    public func open() async throws -> SessionInfo {

        // Start reading what the camera sends unasked (separate from the setup sequence)
        transport.startReceiving()

        // 1. OpenSession (standard PTP), unless opening the link did
        if !transport.opensSessionItself { try await openSession() }

        // 2. SDIO_Connect phases 1 + 2
        try await sdioConnect(phase: .phase1)
        try await sdioConnect(phase: .phase2)

        // 3. SDIO_GetExtDeviceInfo with retry
        let (extInfo, vendorVersion) = try await getExtDeviceInfoWithRetry()

        // Version check: camera rejects if major < camera major
        guard extInfo.majorVersion <= 3 else {
            throw PTPError.versionMismatch(got: 3, need: extInfo.majorVersion)
        }

        // 4. SDIO_Connect phase 3
        try await sdioConnect(phase: .phase3)

        // 5. Optional SDIO_OpenSession
        var sdioOpened = false
        if config.callSDIOOpenSession {
            let called = await trySDIOOpenSession()
            sdioOpened = called
        }

        // 6. Position Key Setting → PC Remote priority (0x01). The camera's own control sequence sets it first
        // in every scenario, so we do too. It is NOT what REC needs: on a real FX3 REC starts and stops with or
        // without it. The FX3 doesn't report 0xD25A, so the set can't be read back. Best-effort.
        await setPositionKeyPCRemote()

        return SessionInfo(
            extDeviceInfo: extInfo,
            vendorCodeVersion: vendorVersion,
            sdioOpenSessionCalled: sdioOpened
        )
    }

    // MARK: - Close

    /// CloseSession then transport disconnect.
    public func close() async {
        // Best-effort: camera may already be gone
        if !transport.opensSessionItself {
            _ = try? await transport.execute(opCode: PTPOpCode.closeSession.rawValue, params: [config.sessionID])
        }
        await transport.disconnect()
    }

    // MARK: - Private steps

    /// OpenSession (0x1002) with SessionID=1. A session a controller left open (an app that quit over USB,
    /// where no connection closes to end it) answers Session_Already_Open: close it and open again, once.
    private func openSession() async throws {
        var (resp, _) = try await transport.execute(opCode: PTPOpCode.openSession.rawValue, params: [config.sessionID])
        if resp.responseCode == PTPResponseCode.sessionAlreadyOpen.rawValue {
            _ = try await transport.execute(opCode: PTPOpCode.closeSession.rawValue, params: [])
            (resp, _) = try await transport.execute(opCode: PTPOpCode.openSession.rawValue, params: [config.sessionID])
        }
        try checkResponse(resp, operation: "OpenSession")
    }

    /// SDIO_Connect (0x9201). A data-IN operation: the camera returns 8 bytes and we send nothing. Sony's
    /// example runs it as `control recv --op=0x9201 --p1=<phase> --p2=0 --p3=0`
    /// (Examples/example-v3-linux/frontend/scripts/authentication.sh). A data-out phase stalls the FX3 in phase 2.
    private func sdioConnect(phase: SDIOConnectPhase) async throws {
        let (resp, _) = try await transport.execute(
            opCode: SDIOOpCode.connect.rawValue,
            params: [phase.rawValue, 0, 0]  // PhaseType, KeyCode1=0, KeyCode2=0
        )
        try checkResponse(resp, operation: "SDIO_Connect phase \(phase.rawValue)")
    }

    /// SDIO_GetExtDeviceInfo (0x9202) with retry on zero-length response
    private func getExtDeviceInfoWithRetry() async throws -> (SDIExtDeviceInfo, UInt32) {
        let deadline = Date().addingTimeInterval(config.extDeviceInfoRetryTimeout)
        var attempt = 0

        while true {
            attempt += 1
            let (resp, data) = try await transport.execute(
                opCode: SDIOOpCode.getExtDeviceInfo.rawValue,
                params: [SDIExtDeviceInfo.initiatorVersion, sdioExtendedCodesFlag]  // Param2=flag
            )
            // Check for non-OK responses other than data-size issues
            if resp.responseCode != PTPResponseCode.ok.rawValue {
                throw PTPError.responseCode(resp.responseCode)
            }
            // Retry if data is empty
            if data.isEmpty {
                if attempt >= config.extDeviceInfoMaxRetries || Date() >= deadline {
                    throw PTPError.timeout
                }
                try await Task.sleep(for: .seconds(config.extDeviceInfoRetryDelay))
                continue
            }
            let extInfo = try parseSDIExtDeviceInfo(data)
            let vendorVersion = resp.params.first ?? 0  // Vendor Code Version in Response Param1
            return (extInfo, vendorVersion)
        }
    }

    /// SDIO_OpenSession (0x9210) — optional; returns whether it was called.
    /// FX6/BURANO not listed in compat table; gracefully skip on not-supported. [Open Question 7]
    /// 0x201E (Session_Already_Open) is treated as success: the FX3 returns this when a prior PC remote
    /// session is still live, which is fine — remote control mode is already active.
    private func trySDIOOpenSession() async -> Bool {
        do {
            let (resp, _) = try await transport.execute(
                opCode: SDIOOpCode.openSession.rawValue,
                params: [config.sessionID, config.functionMode.rawValue]  // SessionID, FunctionMode
            )
            if resp.responseCode == PTPResponseCode.parameterNotSupported.rawValue
                || resp.responseCode == PTPResponseCode.generalError.rawValue {
                // Camera doesn't support SDIO_OpenSession — log and continue [Open Question 7]
                return false
            }
            // 0x201E = Session_Already_Open: camera is already in remote control mode — treat as success
            if resp.responseCode == PTPResponseCode.sessionAlreadyOpen.rawValue {
                return true
            }
            return resp.responseCode == PTPResponseCode.ok.rawValue
        } catch {
            // Network or timeout during optional step — non-fatal
            return false
        }
    }

    /// Set Position Key Setting 0xD25A = 0x01 (PC Remote priority) via SDIO_SetExtDevicePropValue (0x9205).
    /// The camera's own control sequence does this first. Resets to 0x00 when the session closes.
    func setPositionKeyPCRemote() async {
        var data = Data()
        data.appendLE(UInt8(0x01))
        _ = try? await transport.execute(
            opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
            params: [UInt32(SDIPropCode.positionKeySetting.rawValue), sdioExtendedCodesFlag],
            sendData: data
        )
    }

    // MARK: - Helper

    private func checkResponse(_ resp: ParsedCmdResponse, operation: String) throws {
        guard resp.responseCode == PTPResponseCode.ok.rawValue else {
            if resp.responseCode == PTPResponseCode.authenticationFailed.rawValue {
                throw PTPError.authenticationFailed
            }
            throw PTPError.responseCode(resp.responseCode)
        }
    }
}

