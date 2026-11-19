// What SonyCameraBackend and PTPIPSession need from a link to the camera, whatever carries it: PTP-IP over TCP
// (PTPIPTransport, through an SSH tunnel or not) or PTP over USB (PTPUSBTransport, on a Mac). Setting the link up
// differs and stays with each transport; once it's up, the session and backend only run transactions on it.

import Foundation

/// A link's state, reported through `onStateChange`.
public enum PTPTransportState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case disconnected
}

public protocol PTPTransport: AnyObject, Sendable {
    var state: PTPTransportState { get }
    var onStateChange: (@Sendable (PTPTransportState) -> Void)? { get set }
    var onEvent: (@Sendable (ParsedEvent) -> Void)? { get set }
    /// True when opening the link opened the PTP session too (ImageCaptureCore): the Sony session runs inside it,
    /// with no OpenSession or CloseSession of its own.
    var opensSessionItself: Bool { get }
    /// Starts reading what the camera sends unasked: responses and data on PTP-IP's command channel, events on both.
    func startReceiving()
    /// One PTP transaction, start to finish; transactions never overlap. `sendData` is the data-out phase.
    func execute(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data)
    func disconnect() async
}

extension PTPTransport {
    public var opensSessionItself: Bool { false }

    public func execute(opCode: UInt16, params: [UInt32] = []) async throws -> (ParsedCmdResponse, Data) {
        try await execute(opCode: opCode, params: params, sendData: nil)
    }
}
