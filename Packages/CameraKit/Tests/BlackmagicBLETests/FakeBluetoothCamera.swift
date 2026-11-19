import BlackmagicBLE
import Foundation

/// A Blackmagic camera on the far end of a Bluetooth link, as the protocol document describes one: it bonds (if
/// asked to), reports its settings when the link opens (the "initial payload"), takes assignments, and reports changes
/// back. Whether a real camera echoes a change made over Bluetooth is unverified, so echoing can be turned off.
final class FakeBluetoothCamera: BluetoothLink, @unchecked Sendable {
    struct Config {
        var model = "URSA Mini Pro 12K"
        var needsPairing = false
        var status: BlackmagicBluetooth.Status = [.powerOn, .connected, .paired, .versionsVerified, .initialPayloadReceived, .cameraReady]
        /// Report each assignment back, as the camera would after a change from its own buttons.
        var echoes = true
        /// Take REC requests (a camera with no card wouldn't).
        var recordsWhenAsked = true
        var settings: [BMMessage] = FakeBluetoothCamera.ursaMiniPro12K
    }

    /// An URSA Mini Pro 12K on a plausible day: ISO 800, 180°, 5600 K, f/4, 2-stop ND, 4K DCI 23.98, BRAW 5:1, film,
    /// a LUT on, zebra on, idle.
    static let ursaMiniPro12K: [BMMessage] = [
        .assign(.iso, int32: [800]),
        .assign(.shutterAngle, int32: [18000]),
        .assign(.manualWhiteBalance, int16: [5600, 0]),
        .assign(.apertureFStop, fixed16: [4]),
        .assign(.ndFilter, fixed16: [2, 1]),
        .assign(.recordingFormat, int16: [24, 0, 4096, 2160, 0x01]),
        .assign(.codec, int8: [3, 3]),
        .assign(.dynamicRange, int8: [0]),
        .assign(.displayLUT, int8: [2, 1]),
        .assign(.exposureAndFocusTools, int16: [0x1, 0x1F]),
        .assign(.overlayEnables, int16: [0x3, 0x1F]),
        .assign(.zebraLevel, fixed16: [0.75]),
        .assign(.transportMode, int8: [0, 0, 0x20, 2, 2]),
    ]

    let events: AsyncStream<BluetoothLinkEvent>
    private let continuation: AsyncStream<BluetoothLinkEvent>.Continuation
    private let lock = NSLock()
    private var _config: Config
    private var _sent: [Data] = []
    private var _opens = 0
    private var paired = false

    var config: Config {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    /// Everything the backend wrote, message by message.
    var sent: [Data] { lock.withLock { _sent } }
    var opens: Int { lock.withLock { _opens } }

    init(_ config: Config = Config()) {
        _config = config
        let stream = AsyncStream.makeStream(of: BluetoothLinkEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func open() async {
        let (config, firstBond) = lock.withLock { () -> (Config, Bool) in
            _opens += 1
            let first = _config.needsPairing && !paired
            paired = true
            return (_config, first)
        }
        if firstBond {
            continuation.yield(.pairing)  // the code is typed in on the device; the bond completes
            try? await Task.sleep(for: .milliseconds(200))
        }
        continuation.yield(.ready(model: config.model))
        continuation.yield(.status(config.status))
        continuation.yield(.incoming(config.settings.reduce(Data()) { $0 + $1.encoded }))
    }

    func close() async {}

    func send(_ bytes: Data) async throws {
        lock.withLock { _sent.append(bytes) }
        for message in BMMessage.decode(bytes) { take(message) }
    }

    /// Something changed at the camera (a button, a full card).
    func report(_ message: BMMessage) {
        lock.withLock {
            if let i = _config.settings.firstIndex(where: { $0.parameter == message.parameter }) {
                _config.settings[i] = message
            } else {
                _config.settings.append(message)
            }
        }
        continuation.yield(.incoming(message.encoded))
    }

    func status(_ status: BlackmagicBluetooth.Status) {
        continuation.yield(.status(status))
    }

    func timecode(_ bcd: UInt32) {
        continuation.yield(.timecode(bcd))
    }

    func drop(_ why: String?) {
        continuation.yield(.closed(why))
    }

    private func take(_ message: BMMessage) {
        let config = self.config
        switch message.parameter {
        case .setAutoWhiteBalance:
            // It measures, and reports the white balance it came to.
            report(.assign(.manualWhiteBalance, int16: [4950, 3]))
        case .transportMode:
            guard config.recordsWhenAsked else { return }
            report(message)
        default:
            guard message.operation == .assign else { return }
            if config.echoes { report(message) } else {
                lock.withLock {
                    if let i = _config.settings.firstIndex(where: { $0.parameter == message.parameter }) { _config.settings[i] = message }
                }
            }
        }
    }
}
