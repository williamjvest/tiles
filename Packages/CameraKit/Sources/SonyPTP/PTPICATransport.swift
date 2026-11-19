// PTP over USB through Apple's ImageCaptureCore: the camera framework an iPad app gets, which passes PTP commands
// through to a camera on its USB-C port (`requestSendPTPCommand`). Sony's Monitor & Control does USB this way on
// iPhone and iPad, with the camera in USB Connection Mode → Remote Shooting.
//
// ImageCaptureCore opens the PTP session itself when it opens the device, so the Sony session runs inside it: no
// OpenSession or CloseSession of ours (`opensSessionItself`). Every ImageCaptureCore call is made on the main queue:
// its completions come back on "the thread initially called from", and a Swift concurrency thread has no run loop to
// deliver them on.

#if canImport(ImageCaptureCore)
import CameraCore
import Foundation
import ImageCaptureCore

/// ImageCaptureCore's objects aren't Sendable; they're only touched on the main queue or under the lock here.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

public enum PTPICAError: LocalizedError, Equatable {
    case notAllowed
    case notFound(String)
    case openFailed(String)
    case unplugged
    case noAnswer

    public var errorDescription: String? {
        switch self {
        case .notAllowed: "Tiles isn't allowed to control cameras: Settings → Tiles"
        case .notFound(let name): "No \(name) on USB (USB Connection Mode → Remote Shooting?)"
        case .openFailed(let reason): "The camera wouldn't open: \(reason)"
        case .unplugged: "Unplugged"
        case .noAnswer: "The camera stopped answering"
        }
    }
}

/// One camera through ImageCaptureCore, found by its name (iPad: ImageCaptureCore gives apps no serial number) or, on
/// a Mac, its serial number.
public final class PTPICATransport: NSObject, PTPTransport, ICDeviceBrowserDelegate, ICCameraDeviceDelegate,
                                    @unchecked Sendable {
    private typealias Reply = (data: Data, response: Data)

    public var onStateChange: (@Sendable (PTPTransportState) -> Void)?
    public var onEvent: (@Sendable (ParsedEvent) -> Void)?
    public var opensSessionItself: Bool { true }
    /// How long a command waits for the camera before the link counts as lost.
    public var transactionTimeout: TimeInterval = 30

    private let identifier: String
    private let lock = NSLock()
    private let gate = TransactionGate()
    private var _state: PTPTransportState = .idle
    private var browser: ICDeviceBrowser?
    private var camera: ICCameraDevice?
    private var waiting: CheckedContinuation<Unchecked<ICCameraDevice>, Error>?
    private var pending: (id: UInt32, reply: CheckedContinuation<Reply, Error>)?
    private var receiving = false
    private var transactionID: UInt32 = 0

    public init(identifier: String) {
        self.identifier = identifier
    }

    public var state: PTPTransportState { lock.withLock { _state } }

    // MARK: Link

    public func connect() async throws {
        setState(.connecting)
        do {
            let camera = try await find()
            try await open(camera)
            lock.withLock { self.camera = camera.value }
            setState(.connected)
        } catch {
            stopBrowsing()
            setState(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            throw error
        }
    }

    /// Events arrive through `ptpEventHandler` from the moment the device opens; they're passed on from here.
    public func startReceiving() {
        lock.withLock { receiving = true }
    }

    public func disconnect() async {
        let camera = lock.withLock { () -> Unchecked<ICCameraDevice>? in
            defer { self.camera = nil; receiving = false }
            return self.camera.map(Unchecked.init)
        }
        answer(nil, .failure(PTPError.disconnected))
        if let camera {
            // Not waited for: an unplugged camera may never answer it.
            DispatchQueue.main.async {
                camera.value.ptpEventHandler = { _ in }
                camera.value.requestCloseSession(options: nil) { _ in }
            }
        }
        stopBrowsing()
        setState(.disconnected)
    }

    private func find() async throws -> Unchecked<ICCameraDevice> {
        let browser = await MainActor.run { [self] in
            let browser = ICDeviceBrowser()
            browser.delegate = self
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
                ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            return Unchecked(value: browser)
        }
        #if os(iOS)
        let status: ICAuthorizationStatus = try await onMain(within: 60, else: PTPICAError.notAllowed) { done in
            browser.value.requestControlAuthorization { done(.success($0)) }
        }
        guard status == .authorized else { throw PTPICAError.notAllowed }
        #endif
        lock.withLock { self.browser = browser.value }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            DispatchQueue.main.async {
                browser.value.start()
                // Devices already plugged in are announced at once; give up if this one isn't among them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.finishWaiting(.failure(PTPICAError.notFound(self.identifier)))
                }
            }
        }
    }

    private func open(_ camera: Unchecked<ICCameraDevice>) async throws {
        note("opening its session")
        try await onMain(within: 20, else: PTPICAError.openFailed("no answer in 20 s")) { [self] done in
            camera.value.delegate = self
            camera.value.ptpEventHandler = { [weak self] data in self?.received(event: data) }
            camera.value.requestOpenSession(options: nil) { error in
                done(error.map { .failure(PTPICAError.openFailed($0.localizedDescription)) } ?? .success(()))
            }
        }
    }

    /// Starts an ImageCaptureCore request on the main queue and waits for its answer, or fails with `late`: a request
    /// it never answers mustn't leave the camera on Connecting for good.
    private func onMain<T: Sendable>(within seconds: TimeInterval, else late: Error,
                                     _ start: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void)
        async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            DispatchQueue.main.async {
                start { answer.give($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { answer.give(.failure(late)) }
            }
        }
    }

    /// The first answer resumes the waiter; any after it (a reply after the timeout) are dropped.
    private final class Answer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

        func give(_ result: Result<T, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<T, Error>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }

    private func matches(_ device: ICDevice) -> Bool {
        #if os(macOS)
        if device.serialNumberString == identifier { return true }
        #endif
        return device.name == identifier
    }

    private func finishWaiting(_ result: Result<Unchecked<ICCameraDevice>, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Unchecked<ICCameraDevice>, Error>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: result)
    }

    private func stopBrowsing() {
        let browser = Unchecked(value: lock.withLock { () -> ICDeviceBrowser? in
            defer { self.browser = nil }
            return self.browser
        })
        DispatchQueue.main.async { browser.value?.stop() }
    }

    /// The camera went away: whatever command is waiting fails, and so does the link.
    private func lost(_ device: ICDevice) {
        let ours = lock.withLock { () -> Bool in
            guard camera === device else { return false }
            camera = nil
            return true
        }
        guard ours else { return }
        note("ImageCaptureCore removed it")
        answer(nil, .failure(PTPError.disconnected))
        setState(.failed(PTPICAError.unplugged.errorDescription ?? "Unplugged"))
    }

    // MARK: Transactions

    public func execute(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data) {
        try await gate.run { [self] in
            try await self.transact(opCode: opCode, params: params, sendData: sendData)
        }
    }

    private func transact(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data) {
        guard let camera = lock.withLock({ self.camera.map(Unchecked.init) }), state == .connected else {
            throw PTPError.disconnected
        }
        let id = lock.withLock { () -> UInt32 in
            transactionID &+= 1
            return transactionID
        }
        let command = PTPUSBContainer(kind: .command, code: opCode, transactionID: id, params: params).encoded
        let timeout = transactionTimeout
        let reply = try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Reply, Error>) in
            lock.withLock { pending = (id, reply) }
            DispatchQueue.main.async {
                // ImageCaptureCore hands back the data phase's payload and the whole response container.
                camera.value.requestSendPTPCommand(command, outData: sendData) { data, response, error in
                    if let error {
                        self.note(String(format: "op 0x%04X failed: ", opCode) + error.localizedDescription)
                        if self.answer(id, .failure(error)) { self.setState(.failed(error.localizedDescription)) }
                    } else {
                        self.answer(id, .success((data: data, response: response)))
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.answer(id, .failure(PTPError.timeout)) else { return }
                self.note(String(format: "op 0x%04X: no answer in %.0f s", opCode, timeout))
                self.setState(.failed(PTPICAError.noAnswer.errorDescription ?? "No answer"))
            }
        }
        var assembler = PTPUSBContainerAssembler()
        guard let container = try assembler.add(reply.response), container.kind == .response else {
            throw PTPError.unexpectedPacket("ImageCaptureCore response")
        }
        return (ParsedCmdResponse(responseCode: container.code, transactionID: container.transactionID,
                                  params: container.params), reply.data)
    }

    /// Gives the waiting command its reply; `id` nil answers whichever is waiting. False when none was (it was
    /// already answered or timed out).
    @discardableResult
    private func answer(_ id: UInt32?, _ result: Result<Reply, Error>) -> Bool {
        let reply = lock.withLock { () -> CheckedContinuation<Reply, Error>? in
            guard let pending, id == nil || pending.id == id else { return nil }
            self.pending = nil
            return pending.reply
        }
        reply?.resume(with: result)
        return reply != nil
    }

    private func received(event data: Data) {
        guard lock.withLock({ receiving }) else { return }
        var assembler = PTPUSBContainerAssembler()
        guard let event = try? assembler.add(data), event.kind == .event else { return }
        onEvent?(ParsedEvent(eventCode: event.code, transactionID: event.transactionID, params: event.params))
    }

    private func note(_ what: String) {
        ActivityLog.shared.note(USBCameraAddress.host(serial: identifier), what)
    }

    private func setState(_ newState: PTPTransportState) {
        let changed = lock.withLock { () -> Bool in
            guard _state != newState else { return false }
            _state = newState
            return true
        }
        if changed { onStateChange?(newState) }
    }

    // MARK: ICDeviceBrowserDelegate

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        note("ImageCaptureCore sees \"\(camera.name ?? "?")\"")
        guard matches(camera) else { return }
        finishWaiting(.success(Unchecked(value: camera)))
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lost(device)
    }

    // MARK: ICCameraDeviceDelegate (only removal matters; the rest is for photo import)

    public func didRemove(_ device: ICDevice) {
        lost(device)
    }
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
                             error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                             for item: ICCameraItem, error: Error?) {}
}
#endif
