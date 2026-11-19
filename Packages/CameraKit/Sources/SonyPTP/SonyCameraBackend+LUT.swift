import Foundation
import Network
import CameraCore
import SSHTunnel

extension SonyCameraBackend {
    // MARK: - LUT import

    /// Import a .cube file into a User LUT slot on the camera.
    ///
    /// Preconditions checked before sending:
    ///   - 0xD059 (BaseLookImport Command Version) IsEnabled must be 0x02 (DispOnly)
    ///   - 0xD08B (BaseLookImport Operation Enable Status) CurrentValue must be 0x01
    ///   - slot must be 1–16
    ///   - file size must not exceed 0xD0C1 (if the camera reports it)
    ///
    /// Sequence: SDIO_UploadData(0x921A, param=0x00020001) with SDIUploadDataset,
    ///           SDIO_ControlUploadData(0x921B, param=0x00020000) with BaseLookImport Dataset,
    ///           wait for SDIE_ControlUploadDataResult (0xC214) with 30 s timeout.
    ///
    /// After success, refreshes lutNames and emits a new state so the LUT picker updates.
    public func importLUT(_ fileData: Data, fileName: String, slot: Int) async throws {
        guard let transport else { throw PTPError.disconnected }

        // — Precondition: slot range —
        guard slot >= 1, slot <= 16 else {
            throw PTPError.lutImportPrecondition("Slot \(slot) out of range (1–16)")
        }

        // 0xD059 BaseLookImport Command Version: must be IsEnabled=0x02 (DispOnly)
        guard let cmdVerProp = rawProps[SDIPropCode.baseLookImportCommandVersion.rawValue] else {
            throw PTPError.lutImportPrecondition("0xD059 BaseLookImport Command Version not in prop list — camera may not support LUT import")
        }
        guard cmdVerProp.isEnabled == .dispOnly else {
            throw PTPError.lutImportPrecondition("0xD059 IsEnabled=\(cmdVerProp.isEnabled) (need 0x02 DispOnly)")
        }
        guard let commandVersion = cmdVerProp.currentUInt32() else {
            throw PTPError.lutImportPrecondition("0xD059 current value unreadable")
        }

        // 0xD057 Upload Dataset Version
        guard let uploadVerProp = rawProps[SDIPropCode.uploadDatasetVersion.rawValue],
              let uploadVersion = uploadVerProp.currentUInt32() else {
            throw PTPError.lutImportPrecondition("0xD057 Upload Dataset Version not readable")
        }

        // 0xD08B BaseLookImport Operation Enable Status: must be 0x01
        if let enableProp = rawProps[SDIPropCode.baseLookImportOperationEnableStatus.rawValue] {
            guard enableProp.currentUInt8() == 0x01 else {
                throw PTPError.lutImportPrecondition("0xD08B BaseLookImport Operation Enable Status is not 0x01 (enabled)")
            }
        }
        // If 0xD08B is absent the camera doesn't report it; proceed permissively — the next command
        // will reject if the camera isn't ready.

        // 0xD0C1 Maximum upload bytes — check if present and file is within limit
        if let maxProp = rawProps[SDIPropCode.maxUploadBytes.rawValue],
           let maxBytes = maxProp.currentUInt32(), maxBytes > 0 {
            // 0xD0C1 is the max bytes for the data payload of one PTP packet. The SDIUploadDataset for a full
            // Cube file is sent in a single SDIO_UploadData call (no UploadPartialData for CubeFile).
            // The total dataset size must fit within this limit.
            let datasetSize = UInt32(20 + fileName.utf8.count + 1 + fileData.count)
            guard datasetSize <= maxBytes else {
                throw PTPError.lutImportPrecondition("File too large: dataset \(datasetSize) bytes exceeds camera limit \(maxBytes)")
            }
        }

        // — Step 1: SDIO_UploadData (0x921A), param1=0x00020001 (CubeFile) —
        let dataset = buildSDIUploadDataset(uploadVersion: uploadVersion, fileName: fileName, fileData: fileData)
        let (uploadResp, _) = try await transport.execute(
            opCode: SDIOOpCode.uploadData.rawValue,
            params: [sdioUploadDataTypeCubefile],
            sendData: dataset
        )
        guard uploadResp.responseCode == PTPResponseCode.ok.rawValue else {
            throw PTPError.responseCode(uploadResp.responseCode)
        }

        // — Step 2: Register event waiter BEFORE sending ControlUploadData —
        // AsyncStream: handleEvent yields the result; the import waits for the first value.
        var lutStreamContinuation: AsyncStream<LUTImportResult>.Continuation?
        let eventStream = AsyncStream<LUTImportResult> { cont in
            lutStreamContinuation = cont
        }
        pendingLUTImportStreamContinuation = lutStreamContinuation

        let importDataset = buildBaseLookImportDataset(commandVersion: commandVersion, slotIndex: UInt16(slot))
        let (controlResp, _) = try await transport.execute(
            opCode: SDIOOpCode.controlUploadData.rawValue,
            params: [sdioControlUploadBaseLookImport],
            sendData: importDataset
        )
        guard controlResp.responseCode == PTPResponseCode.ok.rawValue else {
            cancelPendingLUTImportIfNeeded()
            throw PTPError.responseCode(controlResp.responseCode)
        }

        // — Step 3: Wait for SDIE_ControlUploadDataResult (0xC214) with 30 s timeout —
        let result: LUTImportResult = await withTaskGroup(of: LUTImportResult.self) { group in
            group.addTask {
                for await r in eventStream { return r }
                return .unknown
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                await self.cancelPendingLUTImportIfNeeded()
                return .unknown
            }
            let r = await group.next() ?? .unknown
            group.cancelAll()
            return r
        }

        switch result {
        case .ok:
            // Refresh LUT names so the display list and lut picker reflect the new import
            if let names = await fetchLUTNames(transport: transport), !names.isEmpty {
                lutNames = names
                let mapper = StateMapper(props: Array(rawProps.values))
                state.lut = mapper.lut(lutNames: lutNames)
                emit()
            }
        case .ngInvalidName:
            throw PTPError.lutImportFailed(.ngInvalidName, detail: "Camera rejected the file name '\(fileName)'")
        case .ngBusy:
            throw PTPError.lutImportFailed(.ngBusy, detail: "Camera busy during import")
        case .ng:
            throw PTPError.lutImportFailed(.ng, detail: "Camera returned NG for LUT import")
        case .unknown:
            throw PTPError.timeout
        }
    }

    func cancelPendingLUTImportIfNeeded() {
        if let cont = pendingLUTImportStreamContinuation {
            pendingLUTImportStreamContinuation = nil
            cont.yield(.unknown)
            cont.finish()
        }
    }


    // MARK: - LUTImportCapable

    /// The 16 User slots with their current names (nil = empty), read fresh from the camera. The import sheet is about to
    /// overwrite one, and a stale or empty cache would show a used slot as empty and skip the overwrite confirmation.
    /// One display-string read (~1 KB), only when the sheet opens. Throws `.notSupported` up front when the body can't
    /// import (0xD059 absent or not DispOnly), and an error rather than a blank list when the read fails.
    public func lutSlots() async throws -> [LUTSlot] {
        guard state.connection.isControllable, let transport else { throw LUTImportError.notConnected }
        let commandVersion = rawProps[SDIPropCode.baseLookImportCommandVersion.rawValue]
        guard commandVersion?.isEnabled == .dispOnly else {
            throw LUTImportError.notSupported("no BaseLook import on this body")
        }
        guard let names = await fetchLUTNames(transport: transport) else {
            throw LUTImportError.other("Couldn't read the camera's LUT slots. Try again.")
        }
        if names != lutNames {  // e.g. a LUT loaded from the camera's own menu since connect
            lutNames = names
            state.lut = StateMapper(props: Array(rawProps.values)).lut(lutNames: lutNames)
            emit()
        }
        // User N is BaseLook value 0x01NN; lutDisplayNames drops "(No Import)", so an empty slot is nil.
        return (1...16).map { LUTSlot(index: $0, name: names[UInt16(0x0100 | $0)]) }
    }

    /// LUTImportCapable entry point — wraps the internal `importLUT` and maps PTPError → LUTImportError.
    public func importLUT(data: Data, name: String, slot: Int) async throws {
        do {
            try await importLUT(data, fileName: name, slot: slot)
        } catch PTPError.disconnected {
            throw LUTImportError.notConnected
        } catch PTPError.timeout {
            throw LUTImportError.timeout
        } catch PTPError.lutImportPrecondition(let msg) {
            if msg.contains("0xD059") { throw LUTImportError.notSupported(msg) }
            if msg.contains("too large") || msg.contains("0xD0C1") { throw LUTImportError.tooLarge }
            throw LUTImportError.other(msg)
        } catch PTPError.lutImportFailed(let result, let detail) {
            switch result {
            case .ngBusy:        throw LUTImportError.busy
            case .ngInvalidName: throw LUTImportError.invalidName
            default:             throw LUTImportError.other(detail)
            }
        } catch {
            throw LUTImportError.other(error.localizedDescription)
        }
    }

    // MARK: - LUT name fetch

    /// Fetch BaseLook display names via SDIO_GetDisplayStringList type 0x00000003.
    /// Returns a map of UINT16 BaseLook value → UTF-8 display string (e.g. "s709", "User 1: TW Show LUT").
    /// Returns nil (no-op, not a failure) if the camera doesn't support the opcode.
    func fetchLUTNames(transport: any PTPTransport) async -> [UInt16: String]? {
        await fetchDisplayStrings(transport: transport, type: SDIODisplayStringListType.baseLookName).map(lutDisplayNames)
    }

    /// The base ISOs as numbers, e.g. [0x01: 12800, 0x02: 800] on the FX3. Gain Base ISO 0xD020 itself only
    /// says High/Low; the numbers come from Camera.Gain.BaseISO.DisplayList (type 8, "ISO 12800").
    func fetchBaseISONames(transport: any PTPTransport) async -> [UInt8: Int]? {
        await fetchDisplayStrings(transport: transport, type: SDIODisplayStringListType.baseISO).map { strings in
            strings.reduce(into: [:]) { result, entry in
                if let iso = parseISOLabel(entry.value) { result[UInt8(truncatingIfNeeded: entry.key)] = iso }
            }
        }
    }

    /// One display string list, for the tools (camctl's strings: step). nil if the camera doesn't give it.
    public func displayStrings(type: UInt32) async -> [UInt16: String]? {
        guard let transport else { return nil }
        return await fetchDisplayStrings(transport: transport, type: type)
    }

    /// SDIO_GetDisplayStringList for one list type. nil if the camera doesn't support it (not an error).
    func fetchDisplayStrings(transport: any PTPTransport, type: UInt32) async -> [UInt16: String]? {
        do {
            let (resp, data) = try await transport.execute(opCode: SDIOOpCode.getDisplayStringList.rawValue,
                                                           params: [type])
            guard resp.responseCode == PTPResponseCode.ok.rawValue, data.count > 8 else { return nil }
            return parseDisplayStringList(data, type: type)
        } catch {
            return nil
        }
    }
}

