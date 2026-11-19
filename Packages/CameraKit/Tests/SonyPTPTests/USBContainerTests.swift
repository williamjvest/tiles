import Foundation
import Testing
@testable import SonyPTP

@Suite("PTP over USB containers")
struct USBContainerTests {
    @Test("A command encodes as length, type, code, transaction ID, then its parameters")
    func encodesACommand() {
        let command = PTPUSBContainer(kind: .command, code: 0x9201, transactionID: 7, params: [1, 0, 0])
        #expect(command.encoded == Data([24, 0, 0, 0, 1, 0, 0x01, 0x92, 7, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(command.params == [1, 0, 0])
    }

    @Test("A data phase spread over several reads comes back whole; a response follows")
    func assemblesAcrossReads() throws {
        let frame = Data((0..<5000).map { UInt8($0 % 251) })
        let data = PTPUSBContainer(kind: .data, code: 0x1009, transactionID: 3, payload: frame).encoded
        var assembler = PTPUSBContainerAssembler()
        #expect(try assembler.add(data.prefix(8)) == nil, "not even a header yet")
        #expect(try assembler.add(data[8..<2048]) == nil)
        let whole = try #require(try assembler.add(data[2048...]))
        #expect(whole.kind == .data && whole.payload == frame && whole.transactionID == 3)
        let response = PTPUSBContainer(kind: .response, code: 0x2001, transactionID: 3, params: [0x136])
        let parsed = try #require(try assembler.add(response.encoded))
        #expect(parsed.kind == .response && parsed.code == 0x2001 && parsed.params == [0x136])
    }

    @Test("One read that ends a container and holds the next gives both, the second from next()")
    func splitsContainersSharingARead() throws {
        let data = PTPUSBContainer(kind: .data, code: 0x1009, transactionID: 4, payload: Data([1, 2, 3])).encoded
        let response = PTPUSBContainer(kind: .response, code: 0x2001, transactionID: 4).encoded
        var assembler = PTPUSBContainerAssembler()
        let first = try #require(try assembler.add(data + response))
        #expect(first.kind == .data && first.payload == Data([1, 2, 3]))
        #expect(try assembler.next()?.kind == .response)
        #expect(try assembler.next() == nil)
    }

    @Test("An empty read (the zero-length packet after a container that filled its last packet) is dropped")
    func dropsZeroLengthPackets() throws {
        var assembler = PTPUSBContainerAssembler()
        #expect(try assembler.add(Data()) == nil)
        let response = PTPUSBContainer(kind: .response, code: 0x2001, transactionID: 1).encoded
        #expect(try assembler.add(response)?.code == 0x2001)
    }

    @Test("A header that isn't a container is an error, and the next read starts clean")
    func rejectsGarbage() throws {
        var assembler = PTPUSBContainerAssembler()
        #expect(throws: PTPError.self) { try assembler.add(Data(repeating: 0xFF, count: 12)) }
        #expect(try assembler.add(PTPUSBContainer(kind: .event, code: 0xC203, transactionID: 0, params: [0xD21E]).encoded)?.params == [0xD21E])
    }
}
