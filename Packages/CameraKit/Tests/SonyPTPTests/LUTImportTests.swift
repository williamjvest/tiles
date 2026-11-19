// LUT import tests — SDIUploadDataset round-trip and FakePTPIPCamera-backed integration.
//
// Verified byte layout citations:
//   SDIUploadDataset: Version(4 UINT32) + OffsetToHeader(4) + HeaderInfoSize(4) + OffsetToFile(4) + FileBinarySize(4)
//   + FileName(null-terminated UTF-8) + FileData
//   BaseLookImport Dataset: Version(4 UINT32) + BaseLookIndex(2 UINT16)
//   SDIE_ControlUploadDataResult (0xC214): param1=result, param2=ControlType

import Testing
import Foundation
@testable import SonyPTP
import Network

// MARK: - Dataset round-trip tests

@Suite("LUT Import — Dataset encoding")
struct LUTDatasetTests {

    @Test("SDIUploadDataset: fixed header is 20 bytes, offsets consistent")
    func uploadDatasetLayout() {
        let fileName = "test.cube"
        let fileData = Data(repeating: 0xAB, count: 64)
        let dataset = buildSDIUploadDataset(uploadVersion: 0x00000064, fileName: fileName, fileData: fileData)

        // Version (4)
        #expect(dataset.readLE(UInt32.self, at: 0) == 0x00000064)

        // Offset to HeaderInfo (4) — must equal 20 (5 × UINT32)
        let offsetToHeader = Int(dataset.readLE(UInt32.self, at: 4))
        #expect(offsetToHeader == 20)

        // HeaderInfo size (4) — fileName bytes + 1 null
        let headerSize = Int(dataset.readLE(UInt32.self, at: 8))
        let expectedHeaderSize = fileName.utf8.count + 1
        #expect(headerSize == expectedHeaderSize)

        // Offset to file binary (4) — 20 + headerSize
        let offsetToFile = Int(dataset.readLE(UInt32.self, at: 12))
        #expect(offsetToFile == 20 + expectedHeaderSize)

        // File binary size (4)
        let fileBinarySize = Int(dataset.readLE(UInt32.self, at: 16))
        #expect(fileBinarySize == fileData.count)

        // HeaderInfo: null-terminated UTF-8 file name
        let nameBytes = Data(dataset[dataset.startIndex + offsetToHeader ..< dataset.startIndex + offsetToHeader + headerSize])
        let name = String(bytes: nameBytes.dropLast(), encoding: .utf8)  // drop null terminator
        #expect(name == fileName)
        #expect(nameBytes.last == 0x00)  // null terminator present

        // File binary matches
        let fileSlice = Data(dataset[dataset.startIndex + offsetToFile ..< dataset.startIndex + offsetToFile + fileBinarySize])
        #expect(fileSlice == fileData)

        // Total size = 20 + headerSize + fileBinarySize
        #expect(dataset.count == 20 + expectedHeaderSize + fileData.count)
    }

    @Test("BaseLookImport Dataset: Version(4) + BaseLookIndex(2)")
    func baseLookImportDatasetLayout() throws {
        let d = buildBaseLookImportDataset(commandVersion: 0x00000064, slotIndex: 0x0003)
        try #require(d.count == 6)
        #expect(d.readLE(UInt32.self, at: 0) == 0x00000064)
        #expect(d.readLE(UInt16.self, at: 4) == 0x0003)
    }

    @Test("SDIUploadDataset handles empty file name gracefully")
    func uploadDatasetEmptyName() {
        let d = buildSDIUploadDataset(uploadVersion: 0x01, fileName: "", fileData: Data([0x01, 0x02]))
        // HeaderInfo is just the null terminator
        let headerSize = Int(d.readLE(UInt32.self, at: 8))
        #expect(headerSize == 1)
        let nullByte = d[d.startIndex + 20]
        #expect(nullByte == 0x00)
    }

    @Test("SDIUploadDataset with non-ASCII file name (UTF-8 encoded)")
    func uploadDatasetUTF8Name() {
        let name = "GK_SLog3_False_Color.cube"
        let d = buildSDIUploadDataset(uploadVersion: 0x64, fileName: name, fileData: Data())
        let headerSize = Int(d.readLE(UInt32.self, at: 8))
        #expect(headerSize == name.utf8.count + 1)
        let nameBytes = Data(d[d.startIndex + 20 ..< d.startIndex + 20 + headerSize - 1])
        #expect(String(bytes: nameBytes, encoding: .utf8) == name)
    }
}

// MARK: - Backend integration tests

@Suite("LUT Import — Backend integration", .serialized)
struct LUTImportBackendTests {

    private func connectedBackend(_ cam: FakePTPIPCamera) async -> (SonyCameraBackend, Task<Void, Never>) {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.port = NWEndpoint.Port(rawValue: cam.port)!
        let store = EphemeralIdentityStore(friendlyName: "lut-test")
        let backend = SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg)
        let task = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return (backend, task)
    }

    @Test("importLUT: OK result — 0x921A and 0x921B sent, 0xC214 OK received", .timeLimit(.minutes(1)))
    func importLUTSuccess() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let fakeData = Data("LUT_3D_SIZE 33\n".utf8)
        try await backend.importLUT(fakeData, fileName: "GK_SLog3.cube", slot: 1)

        // Verify 0x921A was sent with param 0x00020001
        let uploads = cam.lastTransactions.filter { $0.opCode == SDIOOpCode.uploadData.rawValue }
        #expect(uploads.count == 1)
        #expect(uploads.first?.params.first == sdioUploadDataTypeCubefile)

        // Verify 0x921B was sent with param 0x00020000
        let controls = cam.lastTransactions.filter { $0.opCode == SDIOOpCode.controlUploadData.rawValue }
        #expect(controls.count == 1)
        #expect(controls.first?.params.first == sdioControlUploadBaseLookImport)

        // Verify the slot index parsed correctly
        #expect(cam.lastImportSlot == 0x0001)

        // Verify the uploaded dataset has the correct file name
        let dataset = try #require(cam.lastUploadDataset)
        let headerSize = Int(dataset.readLE(UInt32.self, at: 8))
        let offsetToHeader = Int(dataset.readLE(UInt32.self, at: 4))
        let nameBytes = Data(dataset[dataset.startIndex + offsetToHeader ..< dataset.startIndex + offsetToHeader + headerSize - 1])
        let name = String(bytes: nameBytes, encoding: .utf8)
        #expect(name == "GK_SLog3.cube")
    }

    @Test("importLUT: NG Invalid Name result throws lutImportFailed(.ngInvalidName)", .timeLimit(.minutes(1)))
    func importLUTInvalidName() async throws {
        let cam = FakePTPIPCamera()
        cam.config.lutImportResult = .ngInvalidName
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "bad?name.cube", slot: 2)
            #expect(Bool(false), "Should have thrown")
        } catch PTPError.lutImportFailed(let result, _) {
            #expect(result == .ngInvalidName)
        }
    }

    @Test("importLUT: NG Busy result throws lutImportFailed(.ngBusy)", .timeLimit(.minutes(1)))
    func importLUTBusy() async throws {
        let cam = FakePTPIPCamera()
        cam.config.lutImportResult = .ngBusy
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "test.cube", slot: 3)
            #expect(Bool(false), "Should have thrown")
        } catch PTPError.lutImportFailed(let result, _) {
            #expect(result == .ngBusy)
        }
    }

    @Test("importLUT: NG result throws lutImportFailed(.ng)", .timeLimit(.minutes(1)))
    func importLUTNG() async throws {
        let cam = FakePTPIPCamera()
        cam.config.lutImportResult = .ng
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "test.cube", slot: 4)
            #expect(Bool(false), "Should have thrown")
        } catch PTPError.lutImportFailed(let result, _) {
            #expect(result == .ng)
        }
    }

    @Test("importLUT: slot out of range throws lutImportPrecondition", .timeLimit(.minutes(1)))
    func importLUTSlotOutOfRange() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "test.cube", slot: 0)
            #expect(Bool(false), "Should have thrown")
        } catch PTPError.lutImportPrecondition(_) {
            // expected
        }
        do {
            try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "test.cube", slot: 17)
            #expect(Bool(false), "Should have thrown")
        } catch PTPError.lutImportPrecondition(_) {
            // expected
        }
    }

    @Test("importLUT: slot 5 maps to BaseLookIndex 0x0005", .timeLimit(.minutes(1)))
    func importLUTSlotEncoding() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        try await backend.importLUT(Data("LUT_3D_SIZE 17\n".utf8), fileName: "slot5.cube", slot: 5)
        #expect(cam.lastImportSlot == 0x0005)
    }
}

