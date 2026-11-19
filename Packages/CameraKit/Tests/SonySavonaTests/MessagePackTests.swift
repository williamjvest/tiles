import XCTest
@testable import SonySavona

/// Bryan Randell's captured VENICE frames (github.com/bryanrandell/Sony_websocket, no license — the
/// bytes are protocol facts) and MessagePack's spec vectors.
final class MessagePackTests: XCTestCase {
    func testCapturedVENICESetND() throws {
        // 94 00 CC B1 "Property.SetValue" 91 82 B4 "Camera.NDFilter.Mode" A6 "Preset" B5 "Camera.NDFilter.Value" 02
        let frame = try MessagePack.decode(Data(hex: "9400ccb1b150726f70657274792e53657456616c75659182b443616d6572612e4e4446696c7465722e4d6f6465a6507265736574b543616d6572612e4e4446696c7465722e56616c756502"))
        XCTAssertEqual(frame.array?.count, 4)
        XCTAssertEqual(frame[0]?.number, 0)
        XCTAssertEqual(frame[2]?.string, "Property.SetValue")
        XCTAssertEqual(frame[3]?[0]?["Camera.NDFilter.Mode"]?.string, "Preset")
        XCTAssertEqual(frame[3]?[0]?["Camera.NDFilter.Value"]?.number, 2)
        // Re-encode and it's the same bytes (maps sorted, smallest int forms).
        XCTAssertEqual(MessagePack.encode(frame).hexString, "9400ccb1b150726f70657274792e53657456616c75659182b443616d6572612e4e4446696c7465722e4d6f6465a6507265736574b543616d6572612e4e4446696c7465722e56616c756502")
    }

    func testCapturedVENICESendKeys() throws {
        // 94 00 CD 02A4 AF "Button.SendKeys" 91 91 A3 "Rec"
        let frame = try MessagePack.decode(Data(hex: "9400cd02a4af427574746f6e2e53656e644b6579739191a3526563"))
        XCTAssertEqual(frame[2]?.string, "Button.SendKeys")
        XCTAssertEqual(frame[3]?[0]?[0]?.string, "Rec")
        XCTAssertEqual(MessagePack.encode(frame).hexString, "9400cd02a4af427574746f6e2e53656e644b6579739191a3526563")
    }

    func testCapturedVENICEKeepAlive() throws {
        // Property.GetValue on Network.Connection.KeepAlive, params [[…], ["cam"]]
        let hex = "94005bb150726f70657274792e47657456616c75659181bc4e6574776f726b2e436f6e6e656374696f6e2e4b656570416c69766591a363616d"
        let frame = try MessagePack.decode(Data(hex: hex))
        XCTAssertEqual(frame[2]?.string, "Property.GetValue")
        XCTAssertEqual(frame[3]?[0]?["Network.Connection.KeepAlive"]?.array?.first?.string, "cam")
    }

    func testResponseAndNotification() throws {
        let response: MPValue = .array([.int(1), .int(0), .null, .string("venice model")])
        let decoded = try MessagePack.decode(MessagePack.encode(response))
        XCTAssertEqual(decoded[0]?.number, 1)
        XCTAssertEqual(decoded[1]?.number, 0)
        XCTAssertTrue(decoded[2]?.isNull == true)
        XCTAssertEqual(decoded[3]?.string, "venice model")

        let error: MPValue = .array([.int(1), .int(7), .array([.int(403), .string("auth required")]), .null])
        let decodedError = try MessagePack.decode(MessagePack.encode(error))
        XCTAssertEqual(decodedError[2]?.array?.first?.number, 403)
        XCTAssertEqual(decodedError[2]?[1]?.string, "auth required")

        let notification: MPValue = .array([.int(2), .string("Notify.Property.Value.Changed"),
                                            .array([.map(["Camera.NDFilter.Value": .map(["cam": .int(4)])])])])
        let decodedNote = try MessagePack.decode(MessagePack.encode(notification))
        XCTAssertEqual(decodedNote[0]?.number, 2)
        XCTAssertEqual(decodedNote[1]?.string, "Notify.Property.Value.Changed")
        XCTAssertEqual(decodedNote[2]?.array?.first?["Camera.NDFilter.Value"]?["cam"]?.number, 4)
    }

    func testNumberShapes() {
        XCTAssertEqual(MPValue.string("1250EI").number, 1250)
        XCTAssertEqual(MPValue.string("180.0").number, 180)
        XCTAssertEqual(MPValue.map(["cam": .int(32)]).number, 32)
        XCTAssertEqual(MPValue.map(["numerator": .int(56), "denominator": .int(10)]).number!, 5.6, accuracy: 0.001)
        XCTAssertEqual(MPValue.map(["cam": .map(["numerator": .int(560), "denominator": .int(100)])]).number!,
                       5.6, accuracy: 0.001)
        XCTAssertEqual(MPValue.string("On").bool, true)
        XCTAssertEqual(MPValue.map(["cam": .int(4)]).unwrapped.number, 4)
    }

    func testRoundTrip() throws {
        let value: MPValue = .map(["b": .array([.int(1), .string("x")]), "a": .double(1.5), "n": .null, "z": .binary(Data([1, 2]))])
        XCTAssertEqual(try MessagePack.decode(MessagePack.encode(value)), value)
    }
}

extension Data {
    init(hex: String) {
        self.init()
        var chars = Array(hex)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        for i in stride(from: 0, to: chars.count, by: 2) {
            append(UInt8(String(chars[i...i + 1]), radix: 16) ?? 0)
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
