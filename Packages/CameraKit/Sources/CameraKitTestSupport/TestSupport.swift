// Shared helpers for CameraKit test targets.

import Foundation
import CameraCore

// MARK: - Condition wait

/// Polls `condition` every `interval` until it returns true or `timeout` expires.
/// Returns true when the condition held; false on timeout.
@discardableResult
public func waitUntil(
    timeout: TimeInterval = 10,
    interval: TimeInterval = 0.02,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .seconds(interval))
    }
    return condition()
}

/// MainActor variant for UI-state checks.
@discardableResult
@MainActor
public func waitUntilMain(
    timeout: TimeInterval = 10,
    interval: TimeInterval = 0.02,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .seconds(interval))
    }
    return condition()
}

// MARK: - Collect until

/// Collect state updates from an AsyncStream until `predicate` matches, or timeout.
public func collectUntil<State: Sendable>(
    stream: AsyncStream<State>,
    timeout: TimeInterval = 10,
    predicate: @escaping @Sendable (State) -> Bool
) async -> State? {
    await withTaskGroup(of: State?.self) { group in
        group.addTask {
            for await state in stream {
                if predicate(state) { return state }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

// MARK: - Loopback TCP

import Network

/// TCP to a loopback server in a test. A connect the system turns down with EADDRINUSE keeps the local port it picked:
/// all 30 retries of one request got the same port, and netstat at that moment showed
/// why. That port's 4-tuple to the server was still in TIME_WAIT: a server listening on that port had closed a
/// connection from the port this server now listens on (ports on 0 are recycled within the TIME_WAIT's 30 s). So a
/// retry, or a relay that has none, names its own local port. It picks from 40000–48999, outside the ephemeral range
/// where listeners on port 0 and every automatically bound socket live, and outside 30000–39999, where tests pick
/// fixed ports.
public enum LoopbackTCP {
    /// `host`: 127.0.0.1 for the test servers (`LoopbackListener`); ::1 for the app's own Control API server, which
    /// listens on every address, where 127.0.0.1 could reach another app on the same port (`LoopbackListener`'s note).
    public static func connection(to port: UInt16, host: String = "127.0.0.1", freshLocalPort: Bool = false) -> NWConnection {
        let params = NWParameters.tcp
        if freshLocalPort {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                     port: NWEndpoint.Port(rawValue: UInt16.random(in: 40000...48999))!)
        }
        return NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }
}

/// A test server's listener, on 127.0.0.1 and a port the system picks there. One on every address (`.any`) could be
/// given a port another app holds on 127.0.0.1 alone, and the tests' connections to 127.0.0.1 then reached that app
/// instead, failing with "HTTP 404: not found" or never connecting.
public enum LoopbackListener {
    public static func make(_ parameters: NWParameters = .tcp) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }

    /// A server's start, again while the system says the address is in use: a listener on 127.0.0.1 failed so once in
    /// 30 full runs (2026-11-15, the access probe's fakes, its two-in-a-row starts). Five tries.
    public static func retrying(_ start: () async throws -> Void) async throws {
        for attempt in 1 ... 5 {
            do {
                try await start()
                return
            } catch NWError.posix(.EADDRINUSE) where attempt < 5 {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

/// What a fake camera records (the writes it got, the controls pressed) as a test reads it: the fake's queue adds to it
/// while a test polls it, and an array read mid-append crashed whole runs, twice in 30 (2026-11-15: a test polling
/// `propWrites` during Review, "Index out of range" and a release of a freed buffer). Every read and change takes a lock.
@propertyWrapper
public struct Locked<Value>: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let box: Box

    public init(wrappedValue: Value) { box = Box(wrappedValue) }

    public var wrappedValue: Value {
        get { box.lock.withLock { box.value } }
        nonmutating set { box.lock.withLock { box.value = newValue } }
        // In place, under the lock: an append doesn't copy the whole record.
        nonmutating _modify {
            box.lock.lock()
            defer { box.lock.unlock() }
            yield &box.value
        }
    }
}

