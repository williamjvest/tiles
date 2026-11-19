import Testing
import Foundation
import Darwin
@testable import SSHTunnel

@Suite("SSH tunnel")
struct SSHTunnelTests {

    /// A descriptor on a word's last bit (31, 63, …) is the sign bit of fd_set's Int32 word: setting it crashed.
    @Test("Every descriptor's fd_set bit, the sign bit included")
    func fdSetBits() {
        #expect(_SSHCore.fdBit(0) == (0, 1))
        #expect(_SSHCore.fdBit(31) == (0, Int32.min))
        #expect(_SSHCore.fdBit(63) == (1, Int32.min))
        #expect(_SSHCore.fdBit(33) == (1, 2))
    }

    @Test("An unreachable host fails rather than hanging", .timeLimit(.minutes(1)))
    func unreachableHostThrows() async {
        let fwd = SSHPortForwarder(host: "192.0.2.1", port: 22, username: "nobody", password: "nopass")   // TEST-NET
        await #expect(throws: (any Error).self) { _ = try await fwd.start() }
        fwd.stop()
    }

    /// A camera that takes the connection and never answers (still holding the session from before the iPad slept):
    /// the attempt gives up at its deadline and hangs up, so the camera is free for the retry.
    @Test("A server that never answers times out and is hung up on", .timeLimit(.minutes(1)))
    func silentServerTimesOutAndHangsUp() async throws {
        let server = try SilentServer()
        defer { server.close() }
        let fwd = SSHPortForwarder(host: "127.0.0.1", port: Int32(server.port), username: "u", password: "p",
                                   connectTimeout: 0.5)
        let started = Date()
        await #expect(throws: SSHTunnelError.self) { _ = try await fwd.start() }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(server.peerHungUp(within: 2), "the attempt left its connection open")
    }
}

/// Listens on 127.0.0.1 and never sends a byte.
private final class SilentServer {
    let port: UInt16
    private let listenFd: Int32
    private var clientFd: Int32 = -1

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { Darwin.close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        listenFd = fd
        port = UInt16(bigEndian: addr.sin_port)
    }

    /// Accepts the client's connection, then reads until it closes (true) or `seconds` pass (false).
    func peerHungUp(within seconds: TimeInterval) -> Bool {
        guard wait(listenFd, seconds) else { return false }
        clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 256)
        while wait(clientFd, deadline.timeIntervalSinceNow) {
            if recv(clientFd, &buf, buf.count, 0) <= 0 { return true }   // the client's banner, then its close
        }
        return false
    }

    func close() {
        if clientFd >= 0 { Darwin.close(clientFd) }
        Darwin.close(listenFd)
    }

    private func wait(_ fd: Int32, _ seconds: TimeInterval) -> Bool {
        guard seconds > 0 else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, Int32(seconds * 1000)) == 1
    }
}
