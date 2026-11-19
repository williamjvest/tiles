import Testing

/// Suites whose receivers listen on RTMP's port, 1935, run one at a time across every test target: each is
/// `.serialized` in itself, but they ran beside each other. A test that closed its receiver and listened again (live view
/// back within the linger) found the port taken by another suite's, listened elsewhere, and its stream started over: the
/// "picked up within the linger" test failed in two of six full runs on 11/16, and passed alone under load every time.
public struct RTMPPortTrait: SuiteTrait, TestScoping {
    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        await RTMPPortLock.shared.acquire()
        do {
            try await function()
        } catch {
            await RTMPPortLock.shared.release()
            throw error
        }
        await RTMPPortLock.shared.release()
    }
}

extension Trait where Self == RTMPPortTrait {
    /// The suite listens on 1935: it runs while no other such suite does.
    public static var rtmpPort: Self { RTMPPortTrait() }
}

/// First come, first served.
actor RTMPPortLock {
    static let shared = RTMPPortLock()
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else { held = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() }
    }
}
