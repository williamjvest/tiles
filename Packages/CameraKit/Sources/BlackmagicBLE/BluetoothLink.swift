import Foundation

/// Blackmagic's Bluetooth LE services and characteristics, as its Camera Control document gives them. Everything but
/// the device information and the protocol version is encrypted: the first write or
/// subscription starts bonding, and the camera shows a 6-digit code to type on this device.
public enum BlackmagicBluetooth {
    public static let deviceInformationService = "180A"
    public static let manufacturer = "2A29"       // "Blackmagic Design"
    public static let model = "2A24"              // e.g. "URSA Mini Pro"
    public static let cameraService = "291D567A-6D75-11E6-8B77-86F30CA893D3"
    public static let outgoingCameraControl = "5DD3465F-1AEE-4299-8493-D2ECA2F8E1BB"  // write: our messages
    public static let incomingCameraControl = "B864E140-76A0-416A-BF30-5876504537D9"  // notify: the camera's
    public static let timecode = "6D8F2110-86F1-41BF-9AFB-451D87E976C8"               // notify: BCD HHMMSSFF
    public static let cameraStatus = "7FE8691D-95DC-4FC5-8ABD-CA74339B51B9"           // notify, write: power
    public static let deviceName = "FFAC0C52-C9FB-41A0-B063-CC76282EB89C"             // write: shown in its menu
    public static let protocolVersion = "8F1FD018-B508-456F-8F82-3D392BEE2706"        // read

    /// Camera status flags.
    public struct Status: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let powerOn = Status(rawValue: 0x01)
        public static let connected = Status(rawValue: 0x02)
        public static let paired = Status(rawValue: 0x04)
        public static let versionsVerified = Status(rawValue: 0x08)
        public static let initialPayloadReceived = Status(rawValue: 0x10)
        public static let cameraReady = Status(rawValue: 0x20)
    }

    /// A timecode notification's 32-bit BCD value as hours, minutes, seconds and frames (09:12:53:10 is 0x09125310).
    public static func timecode(bcd: UInt32) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        func digits(_ shift: UInt32) -> Int { Int((bcd >> (shift + 4)) & 0xF) * 10 + Int((bcd >> shift) & 0xF) }
        return (digits(24), digits(16), digits(8), digits(0))
    }
}

/// What the link to one camera reports.
public enum BluetoothLinkEvent: Sendable, Equatable {
    /// Found, connected, bonded and subscribed: messages can flow. `model` from the device information service.
    case ready(model: String?)
    /// The camera wants bonding: the system is asking for the code the camera shows.
    case pairing
    /// Camera control bytes from the camera (one or more messages).
    case incoming(Data)
    case timecode(UInt32)
    case status(BlackmagicBluetooth.Status)
    /// Gone, with why if it failed.
    case closed(String?)
}

/// One camera's Bluetooth link: CoreBluetooth on a device (`CoreBluetoothLink`), a fake in tests.
public protocol BluetoothLink: AnyObject, Sendable {
    /// Single consumer: the backend.
    var events: AsyncStream<BluetoothLinkEvent> { get }
    /// Find the camera, connect, bond if needed, subscribe. Progress and failure come as events.
    func open() async
    func close() async
    /// Writes camera control bytes to the outgoing characteristic, returning when the camera has acknowledged them.
    func send(_ bytes: Data) async throws
}

public enum BluetoothLinkError: Error, Equatable, CustomStringConvertible {
    case notReady
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notReady: "The camera's Bluetooth link isn't open."
        case .writeFailed(let why): "The camera didn't take it: \(why)"
        }
    }
}

